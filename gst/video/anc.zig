const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const info = @import("info.zig");
const meta = @import("meta.zig");

const Info = c.GstVideoInfo;
const Buffer = c.GstBuffer;
const Meta = c.GstMeta;

const Vbi = extern struct {
    info: Info,
    work: [*c]u8,
    size: u32,
    offset: c.guint,
    bit16: c.gboolean,
};

fn vbiNew(fmt: c.GstVideoFormat, width: u32) ?*Vbi {
    const bit16 = switch (fmt) {
        c.GST_VIDEO_FORMAT_v210 => true,
        c.GST_VIDEO_FORMAT_UYVY => false,
        else => return null,
    };
    const v: *Vbi = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Vbi))));
    v.bit16 = @intFromBool(bit16);
    info.gst_video_info_init(&v.info);
    if (info.gst_video_info_set_format(&v.info, fmt, width, 1) == 0) {
        c.g_free(v);
        return null;
    }
    v.size = 2 *% width;
    v.work = @ptrCast(c.g_malloc0(if (bit16) v.size *% 2 else v.size));
    v.offset = 0;
    return v;
}

fn vbiCopy(v: *const Vbi) ?*Vbi {
    const r = vbiNew(v.info.finfo[0].format, @bitCast(v.info.width)) orelse return null;
    @memcpy(r.work[0..v.size], v.work[0..v.size]);
    return r;
}

fn vbiFree(v: *Vbi) void {
    c.g_free(v.work);
    c.g_free(v);
}

fn of(p: anytype) ?*Vbi {
    return @ptrCast(@alignCast(p));
}

var parser_once: gtype.Once = .{};
var encoder_once: gtype.Once = .{};

fn parserCopyB(p: c.gpointer) callconv(.c) c.gpointer {
    return @ptrCast(gst_video_vbi_parser_copy(@ptrCast(p)));
}

fn parserFreeB(p: c.gpointer) callconv(.c) void {
    gst_video_vbi_parser_free(@ptrCast(p));
}

fn encoderCopyB(p: c.gpointer) callconv(.c) c.gpointer {
    return @ptrCast(gst_video_vbi_encoder_copy(@ptrCast(p)));
}

fn encoderFreeB(p: c.gpointer) callconv(.c) void {
    gst_video_vbi_encoder_free(@ptrCast(p));
}

pub export fn gst_video_vbi_parser_get_type() c.GType {
    return parser_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoVBIParser", parserCopyB, parserFreeB);
        }
    }.f);
}

pub export fn gst_video_vbi_encoder_get_type() c.GType {
    return encoder_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstVideoVBIEncoder", encoderCopyB, encoderFreeB);
        }
    }.f);
}

pub export fn gst_video_vbi_parser_new(fmt: c.GstVideoFormat, pixel_width: u32) ?*c.GstVideoVBIParser {
    if (!check.that(pixel_width > 0, "gst_video_vbi_parser_new", "pixel_width > 0")) return null;
    return @ptrCast(vbiNew(fmt, pixel_width));
}

pub export fn gst_video_vbi_parser_copy(parser: ?*const c.GstVideoVBIParser) ?*c.GstVideoVBIParser {
    if (!check.that(parser != null, "gst_video_vbi_parser_copy", "parser != NULL")) return null;
    return @ptrCast(vbiCopy(@ptrCast(@alignCast(parser.?))));
}

pub export fn gst_video_vbi_parser_free(parser: ?*c.GstVideoVBIParser) void {
    if (!check.that(parser != null, "gst_video_vbi_parser_free", "parser != NULL")) return;
    vbiFree(of(parser).?);
}

fn fromUyvy(v: *Vbi, data: [*]const u8) void {
    const w: c.guint = @bitCast(v.info.width);
    var y = v.work;
    var i: c.guint = 0;
    if (w < 1280) {
        while (i < w -% 3) : (i += 4) {
            for (0..4) |k| {
                y[0] = data[i + k];
                y += 1;
            }
        }
    } else {
        var uv = y + w;
        while (i < w -% 3) : (i += 4) {
            uv[0] = data[i];
            y[0] = data[i + 1];
            uv[1] = data[i + 2];
            y[1] = data[i + 3];
            uv += 2;
            y += 2;
        }
    }
}

fn fromV210(v: *Vbi, data: [*]const u8) void {
    const w: c.guint = @bitCast(v.info.width);
    const y: [*]u16 = @ptrCast(@alignCast(v.work));
    var yi: usize = 0;
    var ui: usize = w;
    var i: c.guint = 0;
    while (i < w -% 5) : (i += 6) {
        const o = data + (i / 6) * 16;
        var vals: [12]u16 = undefined;
        for (0..4) |q| {
            const a = std.mem.readInt(u32, (o + q * 4)[0..4], .little);
            vals[q * 3] = @intCast(a & 0x3ff);
            vals[q * 3 + 1] = @intCast((a >> 10) & 0x3ff);
            vals[q * 3 + 2] = @intCast((a >> 20) & 0x3ff);
        }
        if (w < 1280) {
            for (vals) |x| {
                y[yi] = x;
                yi += 1;
            }
        } else {
            for (vals, 0..) |x, k| {
                if (k % 2 == 0) {
                    y[ui] = x;
                    ui += 1;
                } else {
                    y[yi] = x;
                    yi += 1;
                }
            }
        }
    }
}

pub export fn gst_video_vbi_parser_add_line(parser: ?*c.GstVideoVBIParser, data: [*c]const u8) void {
    if (!check.that(parser != null, "gst_video_vbi_parser_add_line", "parser != NULL")) return;
    if (!check.that(data != null, "gst_video_vbi_parser_add_line", "data != NULL")) return;
    const v = of(parser).?;
    v.offset = 0;
    switch (v.info.finfo[0].format) {
        c.GST_VIDEO_FORMAT_v210 => fromV210(v, data),
        c.GST_VIDEO_FORMAT_UYVY => fromUyvy(v, data),
        else => unreachable,
    }
}

fn findAnc(comptime T: type, v: *Vbi, anc: *c.GstVideoAncillary) c.GstVideoVBIParserResult {
    const wide = T == u16;
    const d: [*]const T = @ptrCast(@alignCast(v.work));
    const adf: T = if (wide) 0x3fc else 0xfc;
    const ff: T = if (wide) 0x3ff else 0xff;
    while (v.offset + 3 < v.size) {
        const o = v.offset;
        var i: c.guint = 0;
        var composite = false;
        if (d[o] == adf) {
            i += 1;
            composite = true;
        } else if (d[o] == 0 and d[o + 1] == ff and d[o + 2] == ff) {
            i += 3;
        } else {
            v.offset += 1;
            continue;
        }
        if (o + i + 4 >= v.size) {
            v.offset = v.size;
            return c.GST_VIDEO_VBI_PARSER_RESULT_ERROR;
        }
        const did: u8 = @truncate(d[o + i]);
        const sdid: u8 = @truncate(d[o + i + 1]);
        const dc: u8 = @truncate(d[o + i + 2]);
        i += 3;
        if (o + i + dc + 1 >= v.size) {
            v.offset = v.size;
            return c.GST_VIDEO_VBI_PARSER_RESULT_ERROR;
        }
        anc.DID = did;
        anc.SDID_block_number = sdid;
        anc.data_count = dc;
        @memset(anc.data[0..256], 0);
        for (0..dc) |j| anc.data[j] = @truncate(d[o + i + j]);
        i += dc;
        var sum: c.guint = 0;
        var j: c.guint = if (composite) 1 else 3;
        while (j < i) : (j += 1) sum +%= if (wide) d[o + j] & 0x1ff else d[o + j];
        var want: c.guint = undefined;
        if (wide) {
            sum &= 0x1ff;
            sum |= @as(c.guint, @intFromBool(sum >> 8 == 0)) << 9;
            want = d[o + i] & 0x3ff;
        } else {
            sum &= 0xff;
            want = d[o + i];
        }
        if (sum != want) {
            v.offset += 1;
            continue;
        }
        i += 1;
        v.offset += i;
        return c.GST_VIDEO_VBI_PARSER_RESULT_OK;
    }
    return c.GST_VIDEO_VBI_PARSER_RESULT_DONE;
}

pub export fn gst_video_vbi_parser_get_ancillary(parser: ?*c.GstVideoVBIParser, anc: [*c]c.GstVideoAncillary) c.GstVideoVBIParserResult {
    const fname = "gst_video_vbi_parser_get_ancillary";
    if (!check.that(parser != null, fname, "parser != NULL")) return c.GST_VIDEO_VBI_PARSER_RESULT_ERROR;
    if (!check.that(anc != null, fname, "anc != NULL")) return c.GST_VIDEO_VBI_PARSER_RESULT_ERROR;
    const v = of(parser).?;
    if (v.bit16 != 0) return findAnc(u16, v, @ptrCast(anc));
    return findAnc(u8, v, @ptrCast(anc));
}

pub export fn gst_video_vbi_encoder_new(fmt: c.GstVideoFormat, pixel_width: u32) ?*c.GstVideoVBIEncoder {
    if (!check.that(pixel_width > 0, "gst_video_vbi_encoder_new", "pixel_width > 0")) return null;
    return @ptrCast(vbiNew(fmt, pixel_width));
}

pub export fn gst_video_vbi_encoder_copy(encoder: ?*const c.GstVideoVBIEncoder) ?*c.GstVideoVBIEncoder {
    if (!check.that(encoder != null, "gst_video_vbi_encoder_copy", "encoder != NULL")) return null;
    return @ptrCast(vbiCopy(@ptrCast(@alignCast(encoder.?))));
}

pub export fn gst_video_vbi_encoder_free(encoder: ?*c.GstVideoVBIEncoder) void {
    if (!check.that(encoder != null, "gst_video_vbi_encoder_free", "encoder != NULL")) return;
    vbiFree(of(encoder).?);
}

fn withParity(x: u8) u16 {
    return @as(u16, x) | (if (@popCount(x) & 1 != 0) @as(u16, 0x100) else 0x200);
}

pub export fn gst_video_vbi_encoder_add_ancillary(encoder: ?*c.GstVideoVBIEncoder, composite: c.gboolean, DID: u8, SDID_block_number: u8, data: [*c]const u8, data_count: c.guint) c.gboolean {
    const fname = "gst_video_vbi_encoder_add_ancillary";
    if (!check.that(encoder != null, fname, "encoder != NULL")) return 0;
    if (!check.that(data != null, fname, "data != NULL")) return 0;
    if (!check.that(data_count < 256, fname, "data_count < 256")) return 0;
    const v = of(encoder).?;
    const comp = composite != 0;
    if (v.offset + data_count + @as(c.guint, if (comp) 5 else 7) > v.size) return 0;
    var i: usize = 0;
    if (v.bit16 != 0) {
        const w = @as([*]u16, @ptrCast(@alignCast(v.work))) + v.offset;
        if (comp) {
            w[0] = 0x3fc;
            i = 1;
        } else {
            w[0..3].* = .{ 0, 0x3ff, 0x3ff };
            i = 3;
        }
        w[i] = withParity(DID);
        w[i + 1] = withParity(SDID_block_number);
        w[i + 2] = withParity(@truncate(data_count));
        i += 3;
        for (0..data_count) |j| w[i + j] = withParity(data[j]);
        i += data_count;
        var sum: c.guint = 0;
        for ((if (comp) 1 else 3)..i) |j| sum +%= w[j];
        sum &= 0x1ff;
        sum |= @as(c.guint, @intFromBool(sum >> 8 == 0)) << 9;
        w[i] = @truncate(sum);
    } else {
        const w = v.work + v.offset;
        if (comp) {
            w[0] = 0xfc;
            i = 1;
        } else {
            w[0..3].* = .{ 0, 0xff, 0xff };
            i = 3;
        }
        w[i] = DID;
        w[i + 1] = SDID_block_number;
        w[i + 2] = @truncate(data_count);
        i += 3;
        for (0..data_count) |j| w[i + j] = data[j];
        i += data_count;
        var sum: c.guint = 0;
        for ((if (comp) 1 else 3)..i) |j| sum +%= w[j];
        w[i] = @truncate(sum);
    }
    v.offset += @intCast(i + 1);
    return 1;
}

fn toV210(v: *Vbi, data: [*]u8) void {
    const w: c.guint = @bitCast(v.info.width);
    const y: [*]const u16 = @ptrCast(@alignCast(v.work));
    var yi: usize = 0;
    var ui: usize = w;
    var i: c.guint = 0;
    while (i < w -% 5) : (i += 6) {
        var vals: [12]u32 = undefined;
        if (w < 1280) {
            for (0..12) |k| vals[k] = y[yi + k] & 0x3ff;
            yi += 12;
        } else {
            for (0..12) |k| {
                if (k % 2 == 0) {
                    vals[k] = y[ui] & 0x3ff;
                    ui += 1;
                } else {
                    vals[k] = y[yi] & 0x3ff;
                    yi += 1;
                }
            }
        }
        const o = data + (i / 6) * 16;
        for (0..4) |q| std.mem.writeInt(u32, (o + q * 4)[0..4], vals[q * 3] | vals[q * 3 + 1] << 10 | vals[q * 3 + 2] << 20, .little);
    }
}

fn toUyvy(v: *Vbi, data: [*]u8) void {
    const w: c.guint = @bitCast(v.info.width);
    var y = v.work;
    var i: c.guint = 0;
    if (w < 1280) {
        while (i < w -% 3) : (i += 4) {
            for (0..4) |k| {
                data[i + k] = y[0];
                y += 1;
            }
        }
    } else {
        var uv = y + w;
        while (i < w -% 3) : (i += 4) {
            data[i] = uv[0];
            data[i + 1] = y[0];
            data[i + 2] = uv[1];
            data[i + 3] = y[1];
            uv += 2;
            y += 2;
        }
    }
}

pub export fn gst_video_vbi_encoder_write_line(encoder: ?*c.GstVideoVBIEncoder, data: [*c]u8) void {
    if (!check.that(encoder != null, "gst_video_vbi_encoder_write_line", "encoder != NULL")) return;
    if (!check.that(data != null, "gst_video_vbi_encoder_write_line", "data != NULL")) return;
    const v = of(encoder).?;
    if (v.offset == 0) return;
    switch (v.info.finfo[0].format) {
        c.GST_VIDEO_FORMAT_v210 => toV210(v, data),
        c.GST_VIDEO_FORMAT_UYVY => toUyvy(v, data),
        else => unreachable,
    }
    v.offset = 0;
    const n: usize = v.size * @as(usize, if (v.bit16 != 0) 2 else 1);
    @memset(v.work[0..n], 0);
}

fn isBuffer(b: [*c]Buffer) bool {
    return b != null and b[0].mini_object.type == c.gst_buffer_get_type();
}

fn isCopy(t: c.GQuark) bool {
    return t == c._gst_meta_transform_copy;
}

fn once(store: *usize, comptime name: [*:0]const u8, tags: [*c][*c]const u8) c.GType {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, c.gst_meta_api_type_register(name, tags));
    return store.*;
}

fn infoOnce(store: *usize, make: *const fn () [*c]const c.GstMetaInfo) [*c]const c.GstMetaInfo {
    if (c.g_once_init_enter(store) != 0) c.g_once_init_leave(store, @intFromPtr(make()));
    return @ptrFromInt(store.*);
}

fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}

var no_tags = [_][*c]const u8{null};
var size_tags = [_][*c]const u8{ "size", "orientation", "video", null };
var video_tags = [_][*c]const u8{ "video", null };

const Caption = c.GstVideoCaptionMeta;
var caption_api: usize = 0;
var caption_info: usize = 0;

pub export fn gst_video_caption_meta_api_get_type() c.GType {
    return once(&caption_api, "GstVideoCaptionMetaAPI", &no_tags);
}

fn captionTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, _: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Caption, m);
    return @intFromBool(gst_buffer_add_video_caption_meta(dest, s.caption_type, s.data, s.size) != null);
}

fn captionInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const e = cast(Caption, m);
    e.caption_type = c.GST_VIDEO_CAPTION_TYPE_UNKNOWN;
    e.data = null;
    e.size = 0;
    return 1;
}

fn captionFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    c.g_free(cast(Caption, m).data);
}

fn makeCaption() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_caption_meta_api_get_type(), "GstVideoCaptionMeta", @sizeOf(Caption), captionInit, captionFree, captionTransform);
}

pub export fn gst_video_caption_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&caption_info, makeCaption);
}

pub export fn gst_buffer_add_video_caption_meta(buffer: [*c]Buffer, caption_type: c.GstVideoCaptionType, data: [*c]const u8, size: usize) [*c]Caption {
    const fname = "gst_buffer_add_video_caption_meta";
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(data != null, fname, "data != NULL")) return null;
    if (!check.that(size > 0, fname, "size > 0")) return null;
    switch (caption_type) {
        c.GST_VIDEO_CAPTION_TYPE_CEA608_RAW, c.GST_VIDEO_CAPTION_TYPE_CEA608_S334_1A, c.GST_VIDEO_CAPTION_TYPE_CEA708_RAW, c.GST_VIDEO_CAPTION_TYPE_CEA708_CDP => {},
        else => return null,
    }
    const m: ?*Caption = @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_video_caption_meta_get_info(), null)));
    if (!check.that(m != null, fname, "meta != NULL")) return null;
    m.?.caption_type = caption_type;
    m.?.data = @ptrCast(c.g_memdup2(data, size));
    m.?.size = size;
    return m;
}

pub export fn gst_video_caption_type_from_caps(caps: ?*const c.GstCaps) c.GstVideoCaptionType {
    const fname = "gst_video_caption_type_from_caps";
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, fname, "gst_caps_is_fixed (caps)")) return c.GST_VIDEO_CAPTION_TYPE_UNKNOWN;
    const s = c.gst_caps_get_structure(caps, 0);
    if (!check.that(s != null, fname, "s != NULL")) return c.GST_VIDEO_CAPTION_TYPE_UNKNOWN;
    const f = c.gst_structure_get_string(s, "format");
    if (c.gst_structure_has_name(s, "closedcaption/x-cea-608") != 0) {
        if (c.g_strcmp0(f, "raw") == 0) return c.GST_VIDEO_CAPTION_TYPE_CEA608_RAW;
        if (c.g_strcmp0(f, "s334-1a") == 0) return c.GST_VIDEO_CAPTION_TYPE_CEA608_S334_1A;
    } else if (c.gst_structure_has_name(s, "closedcaption/x-cea-708") != 0) {
        if (c.g_strcmp0(f, "cc_data") == 0) return c.GST_VIDEO_CAPTION_TYPE_CEA708_RAW;
        if (c.g_strcmp0(f, "cdp") == 0) return c.GST_VIDEO_CAPTION_TYPE_CEA708_CDP;
    }
    return c.GST_VIDEO_CAPTION_TYPE_UNKNOWN;
}

pub export fn gst_video_caption_type_to_caps(t: c.GstVideoCaptionType) ?*c.GstCaps {
    const fname = "gst_video_caption_type_to_caps";
    if (!check.that(t != c.GST_VIDEO_CAPTION_TYPE_UNKNOWN, fname, "type != GST_VIDEO_CAPTION_TYPE_UNKNOWN")) return null;
    const p: [2][*c]const u8 = switch (t) {
        c.GST_VIDEO_CAPTION_TYPE_CEA608_RAW => .{ "closedcaption/x-cea-608", "raw" },
        c.GST_VIDEO_CAPTION_TYPE_CEA608_S334_1A => .{ "closedcaption/x-cea-608", "s334-1a" },
        c.GST_VIDEO_CAPTION_TYPE_CEA708_RAW => .{ "closedcaption/x-cea-708", "cc_data" },
        c.GST_VIDEO_CAPTION_TYPE_CEA708_CDP => .{ "closedcaption/x-cea-708", "cdp" },
        else => {
            check.reached("video-anc.c", 1128, fname);
            return null;
        },
    };
    return c.gst_caps_new_simple(p[0], "format", c.G_TYPE_STRING, p[1], @as(?*anyopaque, null));
}

const Anc = c.GstAncillaryMeta;
var anc_api: usize = 0;
var anc_info: usize = 0;

pub export fn gst_ancillary_meta_api_get_type() c.GType {
    return once(&anc_api, "GstAncillaryMetaAPI", &no_tags);
}

fn ancInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const a = cast(Anc, m);
    a.field = c.GST_ANCILLARY_META_FIELD_PROGRESSIVE;
    a.c_not_y_channel = 0;
    a.line = 0x7ff;
    a.offset = 0xfff;
    a.DID = 0;
    a.SDID_block_number = 0;
    a.data_count = 0;
    a.data = null;
    a.checksum = 0;
    return 1;
}

fn ancFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    c.g_free(cast(Anc, m).data);
}

fn ancTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, _: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Anc, m);
    const d = cast(Anc, c.gst_buffer_add_meta(dest, gst_ancillary_meta_get_info(), null));
    d.field = s.field;
    d.c_not_y_channel = s.c_not_y_channel;
    d.line = s.line;
    d.offset = s.offset;
    d.DID = s.DID;
    d.SDID_block_number = s.SDID_block_number;
    d.data_count = s.data_count;
    d.data = @ptrCast(@alignCast(c.g_memdup2(s.data, @as(usize, s.data_count & 0xff) * 2)));
    d.checksum = s.checksum;
    return 1;
}

fn makeAnc() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_ancillary_meta_api_get_type(), "GstAncillaryMeta", @sizeOf(Anc), ancInit, ancFree, ancTransform);
}

pub export fn gst_ancillary_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&anc_info, makeAnc);
}

pub export fn gst_buffer_add_ancillary_meta(buffer: [*c]Buffer) [*c]Anc {
    return @ptrCast(@alignCast(c.gst_buffer_add_meta(buffer, gst_ancillary_meta_get_info(), null)));
}

const Afd = c.GstVideoAFDMeta;
var afd_api: usize = 0;
var afd_info: usize = 0;

pub export fn gst_video_afd_meta_api_get_type() c.GType {
    return once(&afd_api, "GstVideoAFDMetaAPI", &size_tags);
}

fn afdInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const e = cast(Afd, m);
    e.field = 0;
    e.spec = c.GST_VIDEO_AFD_SPEC_ATSC_A53;
    e.afd = c.GST_VIDEO_AFD_UNAVAILABLE;
    return 1;
}

fn afdTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, data: c.gpointer) callconv(.c) c.gboolean {
    const s = cast(Afd, m);
    if (isCopy(t)) {
        _ = gst_buffer_add_video_afd_meta(dest, s.field, s.spec, s.afd);
        return 1;
    }
    if (t != meta.gst_video_meta_transform_scale_get_quark()) return 0;
    const tr = cast(c.GstVideoMetaTransform, data);
    const i = tr.in_info[0];
    const o = tr.out_info[0];
    const fl = struct {
        fn f(v: c.gint) f64 {
            return @floatFromInt(v);
        }
    }.f;
    const diff = @abs((fl(i.width) / fl(i.height)) * (fl(i.par_n) / fl(i.par_d)) - (fl(o.width) / fl(o.height)) * (fl(o.par_n) / fl(o.par_d)));
    if (diff < 0.0001) {
        _ = gst_buffer_add_video_afd_meta(dest, s.field, s.spec, s.afd);
        return 1;
    }
    return 0;
}

fn makeAfd() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_afd_meta_api_get_type(), "GstVideoAFDMeta", @sizeOf(Afd), afdInit, null, afdTransform);
}

pub export fn gst_video_afd_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&afd_info, makeAfd);
}

pub export fn gst_buffer_add_video_afd_meta(buffer: [*c]Buffer, field: u8, spec: c.GstVideoAFDSpec, afd: c.GstVideoAFDValue) [*c]Afd {
    const fname = "gst_buffer_add_video_afd_meta";
    const a: i8 = @truncate(@as(c_int, @bitCast(afd)));
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(field <= 1, fname, "field <= 1")) return null;
    if (!check.that(@as(u8, @truncate(spec)) <= 2, fname, "(guint8) spec <= 2")) return null;
    if (!check.that(a <= 0xF, fname, "afd_data <= 0xF")) return null;
    if (!check.that(a != 1 and (a < 5 or a > 7) and a != 12, fname, "afd_data != 1 && (afd_data < 5 || afd_data > 7) && afd_data != 12")) return null;
    if (!check.that(spec != c.GST_VIDEO_AFD_SPEC_DVB_ETSI or a != 0, fname, "(spec != GST_VIDEO_AFD_SPEC_DVB_ETSI) || (afd_data != 0)")) return null;
    const m = cast(Afd, c.gst_buffer_add_meta(buffer, gst_video_afd_meta_get_info(), null));
    m.field = field;
    m.spec = spec;
    m.afd = afd;
    return m;
}

const Bar = c.GstVideoBarMeta;
var bar_api: usize = 0;
var bar_info: usize = 0;

pub export fn gst_video_bar_meta_api_get_type() c.GType {
    return once(&bar_api, "GstVideoBarMetaAPI", &size_tags);
}

fn barInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const e = cast(Bar, m);
    e.field = 0;
    e.is_letterbox = 0;
    e.bar_data1 = 0;
    e.bar_data2 = 0;
    return 1;
}

fn barTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (!isCopy(t)) return 0;
    const s = cast(Bar, m);
    _ = gst_buffer_add_video_bar_meta(dest, s.field, s.is_letterbox, s.bar_data1, s.bar_data2);
    return 1;
}

fn makeBar() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_bar_meta_api_get_type(), "GstVideoBarMeta", @sizeOf(Bar), barInit, null, barTransform);
}

pub export fn gst_video_bar_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&bar_info, makeBar);
}

pub export fn gst_buffer_add_video_bar_meta(buffer: [*c]Buffer, field: u8, is_letterbox: c.gboolean, bar_data1: c.guint, bar_data2: c.guint) [*c]Bar {
    const fname = "gst_buffer_add_video_bar_meta";
    if (!check.that(isBuffer(buffer), fname, "GST_IS_BUFFER (buffer)")) return null;
    if (!check.that(field <= 1, fname, "field <= 1")) return null;
    const m = cast(Bar, c.gst_buffer_add_meta(buffer, gst_video_bar_meta_get_info(), null));
    m.field = field;
    m.is_letterbox = is_letterbox;
    m.bar_data1 = bar_data1;
    m.bar_data2 = bar_data2;
    return m;
}

const Sei = c.GstVideoSEIUserDataUnregisteredMeta;
var sei_api: usize = 0;
var sei_info: usize = 0;

pub export fn gst_video_sei_user_data_unregistered_meta_api_get_type() c.GType {
    return once(&sei_api, "GstVideoSEIUserDataUnregisteredMetaAPI", &video_tags);
}

fn seiInit(m: [*c]Meta, _: c.gpointer, _: [*c]Buffer) callconv(.c) c.gboolean {
    const e = cast(Sei, m);
    e.data = null;
    e.size = 0;
    return 1;
}

fn seiTransform(dest: [*c]Buffer, m: [*c]Meta, _: [*c]Buffer, t: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (!isCopy(t)) return 0;
    const s = cast(Sei, m);
    _ = gst_buffer_add_video_sei_user_data_unregistered_meta(dest, &s.uuid, s.data, s.size);
    return 1;
}

fn seiFree(m: [*c]Meta, _: [*c]Buffer) callconv(.c) void {
    const s = cast(Sei, m);
    c.g_free(s.data);
    s.data = null;
}

fn makeSei() [*c]const c.GstMetaInfo {
    return c.gst_meta_register(gst_video_sei_user_data_unregistered_meta_api_get_type(), "GstVideoSEIUserDataUnregisteredMeta", @sizeOf(Sei), seiInit, seiFree, seiTransform);
}

pub export fn gst_video_sei_user_data_unregistered_meta_get_info() [*c]const c.GstMetaInfo {
    return infoOnce(&sei_info, makeSei);
}

pub export fn gst_buffer_add_video_sei_user_data_unregistered_meta(buffer: [*c]Buffer, uuid: [*c]u8, data: [*c]u8, size: usize) [*c]Sei {
    if (!check.that(isBuffer(buffer), "gst_buffer_add_video_sei_user_data_unregistered_meta", "GST_IS_BUFFER (buffer)")) return null;
    const m = cast(Sei, c.gst_buffer_add_meta(buffer, gst_video_sei_user_data_unregistered_meta_get_info(), null));
    @memcpy(m.uuid[0..16], uuid[0..16]);
    const d: [*]u8 = @ptrCast(c.g_malloc(size));
    if (size > 0) @memcpy(d[0..size], data[0..size]);
    m.data = d;
    m.size = size;
    return m;
}

const MISP = [3][16]u8{
    .{ 0x4D, 0x49, 0x53, 0x50, 0x6D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x65, 0x63, 0x74, 0x69, 0x6D, 0x65 },
    .{ 0xA8, 0x68, 0x7D, 0xD4, 0xD7, 0x59, 0x37, 0x58, 0xA5, 0xCE, 0xF0, 0x33, 0x8B, 0x65, 0x45, 0xF1 },
    .{ 0xCF, 0x84, 0x82, 0x78, 0xEE, 0x23, 0x30, 0x6C, 0x92, 0x65, 0xE8, 0xFE, 0xF2, 0x2F, 0xB8, 0xB8 },
};

pub export fn gst_video_sei_user_data_unregistered_parse_precision_time_stamp(user_data: [*c]Sei, status: [*c]u8, precision_time_stamp: [*c]u64) c.gboolean {
    const u = &user_data[0];
    var known = false;
    for (MISP) |id| {
        if (std.mem.eql(u8, &u.uuid, &id)) known = true;
    }
    if (!known or u.size < 12) return 0;
    const d = u.data;
    status[0] = d[0];
    var v: u64 = 0;
    for ([_]usize{ 1, 2, 4, 5, 7, 8, 10, 11 }) |k| v = v << 8 | d[k];
    precision_time_stamp[0] = v;
    return 1;
}
