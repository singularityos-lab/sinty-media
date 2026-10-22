const std = @import("std");
const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

pub const DOMAIN = "GStreamer-RIFF";
const FILE = "../gst-libs/gst/riff/riff-read.c";

pub var debug_cat: [*c]c.GstDebugCategory = null;

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

fn le32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

fn le16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}

fn even(v: anytype) @TypeOf(v) {
    return (v + 1) & ~@as(@TypeOf(v), 1);
}

const JUNK = c.GST_RIFF_TAG_JUNK;
const JUNQ = c.GST_RIFF_TAG_JUNQ;

pub export fn gst_riff_init() void {
    debug_cat = c._gst_debug_category_new("riff", 0, "RIFF I/O");
}

pub export fn gst_riff_read_chunk(el: [*c]c.GstElement, pad: ?*c.GstPad, offset_io: [*c]c_ulong, tag: [*c]c_uint, out: [*c][*c]c.GstBuffer) c.GstFlowReturn {
    const f = "gst_riff_read_chunk";
    if (!that(el != null, f, "element != NULL")) return c.GST_FLOW_ERROR;
    if (!that(pad != null, f, "pad != NULL")) return c.GST_FLOW_ERROR;
    if (!that(offset_io != null, f, "_offset != NULL")) return c.GST_FLOW_ERROR;
    if (!that(tag != null, f, "tag != NULL")) return c.GST_FLOW_ERROR;
    if (!that(out != null, f, "_chunk_data != NULL")) return c.GST_FLOW_ERROR;
    var offset = offset_io.*;
    while (true) {
        var buf: [*c]c.GstBuffer = null;
        var res = c.gst_pad_pull_range(pad, offset, 8, &buf);
        if (res != c.GST_FLOW_OK) return res;
        if (c.gst_buffer_get_size(buf) < 8) {
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_EOS;
        }
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
        tag.* = le32(map.data);
        var size: c.guint = le32(map.data + 4);
        c.gst_buffer_unmap(buf, &map);
        c.gst_buffer_unref(buf);
        if (tag.* == JUNK or tag.* == JUNQ) {
            size = even(size);
            offset_io.* +%= 8 + size;
            offset +%= 8 + size;
            continue;
        }
        buf = null;
        res = c.gst_pad_pull_range(pad, offset + 8, size, &buf);
        if (res != c.GST_FLOW_OK) return res;
        if (c.gst_buffer_get_size(buf) < size) {
            c.gst_buffer_unref(buf);
            return c.GST_FLOW_EOS;
        }
        out.* = buf;
        offset_io.* +%= 8 + even(size);
        return c.GST_FLOW_OK;
    }
}

pub export fn gst_riff_parse_chunk(el: [*c]c.GstElement, buf: [*c]c.GstBuffer, offset_io: [*c]c.guint, fourcc_out: [*c]c_uint, out: [*c][*c]c.GstBuffer) c.gboolean {
    const f = "gst_riff_parse_chunk";
    if (!that(el != null, f, "element != NULL")) return 0;
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(offset_io != null, f, "_offset != NULL")) return 0;
    if (!that(fourcc_out != null, f, "_fourcc != NULL")) return 0;
    if (!that(out != null, f, "chunk_data != NULL")) return 0;
    out.* = null;
    fourcc_out.* = 0;
    const offset = offset_io.*;
    const bufsize: c.guint = @truncate(c.gst_buffer_get_size(buf));
    if (bufsize == offset) return 0;
    if (bufsize < offset +% 8) return 0;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
    const tagv = le32(map.data + offset);
    var size: c.guint = le32(map.data + offset + 4);
    c.gst_buffer_unmap(buf, &map);
    if (size > std.math.maxInt(c.gint)) return 0;
    if (bufsize < size +% 8 +% offset) size = bufsize -% 8 -% offset;
    out.* = if (size != 0) c.gst_buffer_copy_region(buf, c.GST_BUFFER_COPY_ALL, offset + 8, size) else null;
    fourcc_out.* = tagv;
    offset_io.* +%= 8 + even(size);
    return 1;
}

fn wrongType(el: [*c]c.GstElement, debug: [*c]u8, line: c.gint) void {
    c.gst_element_message_full(el, c.GST_MESSAGE_ERROR, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_WRONG_TYPE, null, debug, FILE, "gst_riff_parse_file_header", line);
}

pub export fn gst_riff_parse_file_header(el: [*c]c.GstElement, buf: [*c]c.GstBuffer, doctype: [*c]c_uint) c.gboolean {
    const f = "gst_riff_parse_file_header";
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(doctype != null, f, "doctype != NULL")) return 0;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
    defer {
        c.gst_buffer_unmap(buf, &map);
        c.gst_buffer_unref(buf);
    }
    if (map.size < 12) {
        wrongType(el, c.g_strdup_printf("Not enough data to parse RIFF header (%lu available, %d needed)", map.size, @as(c_int, 12)), 252);
        return 0;
    }
    const tag = le32(map.data);
    if (tag != c.GST_RIFF_TAG_RIFF and tag != c.GST_RIFF_TAG_AVF0 and tag != c.GST_RIFF_TAG_RF64) {
        wrongType(el, c.g_strdup_printf("Stream is no RIFF stream: 0x%x", tag), 261);
        return 0;
    }
    doctype.* = le32(map.data + 8);
    return 1;
}

fn dupHeader(comptime T: type, buf: [*c]c.GstBuffer, out: *[*c]T, map: *c.GstMapInfo) bool {
    _ = c.gst_buffer_map(buf, map, c.GST_MAP_READ);
    if (map.size < @sizeOf(T)) {
        c.gst_buffer_unmap(buf, map);
        c.gst_buffer_unref(buf);
        return false;
    }
    out.* = @ptrCast(@alignCast(c.g_memdup2(map.data, map.size)));
    return true;
}

pub export fn gst_riff_parse_strh(_: [*c]c.GstElement, buf: [*c]c.GstBuffer, out: [*c][*c]c.gst_riff_strh) c.gboolean {
    const f = "gst_riff_parse_strh";
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(out != null, f, "_strh != NULL")) return 0;
    var map: c.GstMapInfo = undefined;
    var strh: [*c]c.gst_riff_strh = null;
    if (!dupHeader(c.gst_riff_strh, buf, &strh, &map)) return 0;
    c.gst_buffer_unmap(buf, &map);
    c.gst_buffer_unref(buf);
    if (strh[0].scale == 0) strh[0].scale = 1;
    if (strh[0].rate == 0) strh[0].rate = 1;
    out.* = strh;
    return 1;
}

pub export fn gst_riff_parse_strf_vids(_: [*c]c.GstElement, buf: [*c]c.GstBuffer, out: [*c][*c]c.gst_riff_strf_vids, data: [*c][*c]c.GstBuffer) c.gboolean {
    const f = "gst_riff_parse_strf_vids";
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(out != null, f, "_strf != NULL")) return 0;
    if (!that(data != null, f, "data != NULL")) return 0;
    var map: c.GstMapInfo = undefined;
    var strf: [*c]c.gst_riff_strf_vids = null;
    if (!dupHeader(c.gst_riff_strf_vids, buf, &strf, &map)) return 0;
    c.gst_buffer_unmap(buf, &map);
    data.* = null;
    if (strf[0].size > map.size) strf[0].size = @truncate(map.size);
    const hs = @sizeOf(c.gst_riff_strf_vids);
    if (hs < map.size) data.* = c.gst_buffer_copy_region(buf, c.GST_BUFFER_COPY_ALL, hs, map.size - hs);
    c.gst_buffer_unref(buf);
    out.* = strf;
    return 1;
}

pub export fn gst_riff_parse_strf_auds(_: [*c]c.GstElement, buf: [*c]c.GstBuffer, out: [*c][*c]c.gst_riff_strf_auds, data: [*c][*c]c.GstBuffer) c.gboolean {
    const f = "gst_riff_parse_strf_auds";
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(out != null, f, "_strf != NULL")) return 0;
    if (!that(data != null, f, "data != NULL")) return 0;
    var map: c.GstMapInfo = undefined;
    var strf: [*c]c.gst_riff_strf_auds = null;
    if (!dupHeader(c.gst_riff_strf_auds, buf, &strf, &map)) return 0;
    const hs = @sizeOf(c.gst_riff_strf_auds);
    data.* = null;
    if (map.size > hs + 2) {
        var len: usize = le16(map.data + 16);
        if (len + 2 + hs > map.size) len = map.size - 2 - hs;
        if (len != 0) data.* = c.gst_buffer_copy_region(buf, c.GST_BUFFER_COPY_ALL, hs + 2, len);
    }
    c.gst_buffer_unmap(buf, &map);
    c.gst_buffer_unref(buf);
    out.* = strf;
    return 1;
}

pub export fn gst_riff_parse_strf_iavs(_: [*c]c.GstElement, buf: [*c]c.GstBuffer, out: [*c][*c]c.gst_riff_strf_iavs, data: [*c][*c]c.GstBuffer) c.gboolean {
    const f = "gst_riff_parse_strf_iavs";
    if (!that(buf != null, f, "buf != NULL")) return 0;
    if (!that(out != null, f, "_strf != NULL")) return 0;
    if (!that(data != null, f, "data != NULL")) return 0;
    var map: c.GstMapInfo = undefined;
    var strf: [*c]c.gst_riff_strf_iavs = null;
    if (!dupHeader(c.gst_riff_strf_iavs, buf, &strf, &map)) return 0;
    c.gst_buffer_unmap(buf, &map);
    c.gst_buffer_unref(buf);
    out.* = strf;
    data.* = null;
    return 1;
}

const env_vars = [_:null]?[*:0]const u8{ "GST_AVI_TAG_ENCODING", "GST_RIFF_TAG_ENCODING", "GST_TAG_ENCODING" };

fn tagValue(list: ?*c.GstTagList, kind: [*:0]const u8, ptr: [*]const u8, size: c.guint) void {
    const t = c.gst_tag_get_type(kind);
    const val = c.gst_tag_freeform_string_to_utf8(@ptrCast(ptr), @intCast(size), @ptrCast(@constCast(&env_vars)));
    if (val == null) return;
    defer c.g_free(val);
    if (t == c.G_TYPE_STRING) {
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, kind, val, @as(?*anyopaque, null));
        return;
    }
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, t);
    if (c.gst_value_deserialize(&v, val) != 0) c.gst_tag_list_add_value(list, c.GST_TAG_MERGE_APPEND, kind, &v);
    c.g_value_unset(&v);
}

fn fourcc(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

fn infoTag(tag: u32) ?[*:0]const u8 {
    return switch (tag) {
        fourcc("IARL") => c.GST_TAG_LOCATION,
        fourcc("IAAR") => c.GST_TAG_ALBUM_ARTIST,
        fourcc("IART") => c.GST_TAG_ARTIST,
        fourcc("ICMT") => c.GST_TAG_COMMENT,
        fourcc("ICOP") => c.GST_TAG_COPYRIGHT,
        fourcc("ICRD") => c.GST_TAG_DATE_TIME,
        fourcc("IGNR") => c.GST_TAG_GENRE,
        fourcc("IKEY") => c.GST_TAG_KEYWORDS,
        fourcc("INAM") => c.GST_TAG_TITLE,
        fourcc("IPRD") => c.GST_TAG_ALBUM,
        fourcc("ISBJ") => c.GST_TAG_ALBUM_ARTIST,
        fourcc("ISFT") => c.GST_TAG_ENCODER,
        fourcc("ISRC") => c.GST_TAG_ISRC,
        fourcc("ITRK") => c.GST_TAG_TRACK_NUMBER,
        else => null,
    };
}

pub export fn gst_riff_parse_info(_: [*c]c.GstElement, buf: [*c]c.GstBuffer, out: [*c]?*c.GstTagList) void {
    if (!that(out != null, "gst_riff_parse_info", "_taglist != NULL")) return;
    if (buf == null) {
        out.* = null;
        return;
    }
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buf, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(buf, &map);
    const list = c.gst_tag_list_new_empty();
    var ptr: [*]const u8 = map.data;
    var left: usize = map.size;
    while (left > 8) {
        const tag = le32(ptr) & 0xDFDFDFDF;
        var tsize: usize = le32(ptr + 4);
        left -= 8;
        ptr += 8;
        if (tsize > left) tsize = left;
        if (infoTag(tag)) |kind| {
            if (ptr[0] != 0) tagValue(list, kind, ptr, @intCast(tsize));
        }
        if (tsize & 1 != 0) {
            tsize += 1;
            if (tsize > left) tsize = left;
        }
        ptr += tsize;
        left -= tsize;
    }
    if (c.gst_tag_list_is_empty(list) == 0) {
        out.* = list;
    } else {
        out.* = null;
        c.gst_tag_list_unref(list);
    }
}
