const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tags = @import("tags.zig");
const id3 = @import("id3.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const HDR_SIZE = 10;
const FLAG_UNSYNC = 0x80;
const FLAG_EXTHDR = 0x40;
const FLAG_FOOTER = 0x10;
const F_COMPRESSION = 0x0008;
const F_ENCRYPTION = 0x0004;
const F_UNSYNC = 0x0002;
const F_DLI = 0x0001;
const V23_MASK = 0x4000 | 0x2000 | 0x1000 | 0x0040 | 0x0008 | 0x0004;
const ENC_ISO8859 = 0;
const ENC_UTF16 = 1;
const ENC_UTF16BE = 2;
const ENC_UTF8 = 3;
const FRAME_TAG = "private-id3v2-frame";
const NONE = @as(?*anyopaque, null);

const Work = struct {
    version: u16 = 0,
    flags: u8 = 0,
    frame_data: [*c]u8 = null,
    frame_data_size: u32 = 0,
    tags: [*c]c.GstTagList = null,
    cur_frame_size: c.guint = 0,
    frame_id: [*c]u8 = null,
    frame_flags: u16 = 0,
    parse_data: [*c]u8 = null,
    parse_size: c.guint = 0,
    pending_month: c.guint = 0,
    pending_day: c.guint = 0,
};

fn major(v: u16) u16 {
    return v >> 8;
}

fn be16(p: [*c]const u8) u16 {
    return @as(u16, p[0]) << 8 | p[1];
}

fn be32(p: [*c]const u8) u32 {
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | p[3];
}

fn synch(data: [*c]const u8) c.guint {
    var r: c.guint = 0;
    var invalid: u8 = 0;
    for (0..4) |i| {
        invalid |= data[i] & 0x80;
        r |= @as(c.guint, data[i] & 0x7f) << @intCast((3 - i) * 7);
    }
    if (invalid != 0) {
        r = 0;
        for (0..4) |i| r |= @as(c.guint, data[i]) << @intCast((3 - i) * 8);
    }
    return r;
}

pub export fn gst_tag_get_id3v2_tag_size(buffer: [*c]c.GstBuffer) c.guint {
    if (!check.that(buffer != null, "gst_tag_get_id3v2_tag_size", "buffer != NULL")) return 0;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(buffer, &info);
    if (info.size < HDR_SIZE) return 0;
    if (info.data[0] != 'I' or info.data[1] != 'D' or info.data[2] != '3') return 0;
    const flags = info.data[5];
    var r = synch(info.data + 6);
    if (r == 0) return HDR_SIZE;
    r +%= HDR_SIZE;
    if (flags & FLAG_FOOTER != 0) r +%= 10;
    return r;
}

fn ununsync(data: [*c]const u8, size: *u32) [*c]u8 {
    const out: [*c]u8 = @ptrCast(c.g_malloc(size.*));
    var uu = out;
    var p = data;
    const end = data + size.*;
    while (@intFromPtr(p) < @intFromPtr(end) - 1) : ({
        p += 1;
        uu += 1;
    }) {
        uu[0] = p[0];
        if (p[0] == 0xff and p[1] == 0x00) p += 1;
    }
    if (@intFromPtr(p) < @intFromPtr(end)) {
        uu[0] = p[0];
        uu += 1;
    }
    size.* = @intCast(@intFromPtr(uu) - @intFromPtr(out));
    return out;
}

const OBSOLETE = [_][]const u8{ "CRM", "EQU", "LNK", "RVA", "TIM", "TSI", "EQUA", "RVAD", "TIME", "TRDA", "TSIZ" };
const CONVERSIONS = [_][2][]const u8{
    .{ "TORY", "TDOR" }, .{ "TYER", "TDRC" }, .{ "BUF", "RBUF" }, .{ "CNT", "PCNT" }, .{ "COM", "COMM" }, .{ "CRA", "AENC" }, .{ "ETC", "ETCO" }, .{ "GEO", "GEOB" },
    .{ "IPL", "TIPL" },  .{ "MCI", "MCDI" },  .{ "MLL", "MLLT" }, .{ "PIC", "APIC" }, .{ "POP", "POPM" }, .{ "REV", "RVRB" }, .{ "SLT", "SYLT" }, .{ "STC", "SYTC" },
    .{ "TAL", "TALB" },  .{ "TBP", "TBPM" },  .{ "TCM", "TCOM" }, .{ "TCO", "TCON" }, .{ "TCR", "TCOP" }, .{ "TDA", "TDAT" }, .{ "TDY", "TDLY" }, .{ "TEN", "TENC" },
    .{ "TFT", "TFLT" },  .{ "TKE", "TKEY" },  .{ "TLA", "TLAN" }, .{ "TLE", "TLEN" }, .{ "TMT", "TMED" }, .{ "TOA", "TOAL" }, .{ "TOF", "TOFN" }, .{ "TOL", "TOLY" },
    .{ "TOR", "TDOR" },  .{ "TOT", "TOAL" },  .{ "TP1", "TPE1" }, .{ "TP2", "TPE2" }, .{ "TP3", "TPE3" }, .{ "TP4", "TPE4" }, .{ "TPA", "TPOS" }, .{ "TPB", "TPUB" },
    .{ "TRC", "TSRC" },  .{ "TRD", "TDRC" },  .{ "TRK", "TRCK" }, .{ "TSS", "TSSE" }, .{ "TT1", "TIT1" }, .{ "TT2", "TIT2" }, .{ "TT3", "TIT3" }, .{ "TXT", "TOLY" },
    .{ "TXX", "TXXX" },  .{ "TYE", "TDRC" },  .{ "UFI", "UFID" }, .{ "ULT", "USLT" }, .{ "WAF", "WOAF" }, .{ "WAR", "WOAR" }, .{ "WAS", "WOAS" }, .{ "WCM", "WCOM" },
    .{ "WCP", "WCOP" },  .{ "WPB", "WPUB" },  .{ "WXX", "WXXX" },
};

fn convertFid(id: *[5]u8) bool {
    const s = std.mem.sliceTo(id, 0);
    for (OBSOLETE) |o| {
        if (std.mem.eql(u8, s, o)) return true;
    }
    for (CONVERSIONS) |cv| {
        if (std.mem.eql(u8, s, cv[0])) {
            @memcpy(id[0..4], cv[1]);
            id[4] = 0;
            return false;
        }
    }
    return false;
}

fn addBlob(w: *Work, data: [*c]u8, size: c.guint) void {
    const blob = c.gst_buffer_new_allocate(null, size, null);
    _ = c.gst_buffer_fill(blob, 0, data, size);
    const sample = c.gst_sample_new(blob, null, null, null);
    c.gst_buffer_unref(blob);
    for (0..4) |i| {
        if (!c.g_ascii_isalnum(data[i])) data[i] = '_';
    }
    c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, FRAME_TAG, sample, NONE);
    c.gst_mini_object_unref(@ptrCast(@alignCast(sample)));
}

fn framesToTagList(w: *Work) void {
    if (w.flags & FLAG_EXTHDR != 0) {
        if (w.frame_data_size < 4) return;
        var ext = synch(w.frame_data);
        if (major(w.version) <= 3) ext +%= 4;
        if (ext < 6 or ext > w.frame_data_size) return;
        const flag_bytes = w.frame_data[4];
        if (5 + @as(u32, flag_bytes) > w.frame_data_size) return;
        w.frame_data += ext;
        w.frame_data_size -= ext;
    }
    const hdr: u32 = if (major(w.version) <= 2) 6 else 10;
    if (w.frame_data_size <= hdr) return;
    w.tags = c.gst_tag_list_new_empty();
    while (w.frame_data_size > hdr) {
        var size: c.guint = 0;
        var id: [5]u8 = .{ 0, 0, 0, 0, 0 };
        var flags: u16 = 0;
        var obsolete = false;
        const d = w.frame_data;
        if (major(w.version) <= 2) {
            id[0] = d[0];
            id[1] = d[1];
            id[2] = d[2];
            obsolete = convertFid(&id);
            size = @as(c.guint, d[3]) << 16 | @as(c.guint, d[4]) << 8 | d[5];
        } else {
            @memcpy(id[0..4], d[0..4]);
            size = if (major(w.version) == 3) be32(d + 4) else synch(d + 4);
            flags = be16(d + 8);
            if (major(w.version) == 3) {
                flags &= V23_MASK;
                obsolete = convertFid(&id);
            }
        }
        w.frame_data += hdr;
        w.frame_data_size -= hdr;
        if (size > w.frame_data_size or id[0] == 0) break;
        const n: usize = if (major(w.version) <= 2) 3 else 4;
        for (0..n) |i| {
            if (!c.g_ascii_isalnum(id[i])) id[i] = '_';
        }
        if (!obsolete) {
            w.cur_frame_size = size;
            w.frame_id = &id;
            w.frame_flags = flags;
            if (!parseFrame(w)) addBlob(w, w.frame_data - hdr, hdr + size);
            w.frame_id = null;
        }
        w.frame_data += size;
        w.frame_data_size -= size;
    }
    if (c.gst_tag_list_n_tags(w.tags) == 0) {
        c.gst_tag_list_unref(w.tags);
        w.tags = null;
        return;
    }
    if (w.pending_day != 0 and w.pending_month != 0) {
        var dt: ?*c.GstDateTime = null;
        if (c.gst_tag_list_get_date_time(w.tags, c.GST_TAG_DATE_TIME, &dt) != 0) {
            const dt2 = c.gst_date_time_new_ymd(c.gst_date_time_get_year(dt), @intCast(w.pending_month), @intCast(w.pending_day));
            c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_DATE_TIME, dt2, NONE);
            c.gst_date_time_unref(dt2);
            c.gst_date_time_unref(dt);
        }
    }
}

pub export fn gst_tag_list_from_id3v2_tag(buffer: [*c]c.GstBuffer) [*c]c.GstTagList {
    tags.gst_tag_register_musicbrainz_tags();
    const read_size = gst_tag_get_id3v2_tag_size(buffer);
    if (read_size < HDR_SIZE) return null;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(buffer, &info);
    const version = be16(info.data + 3);
    const flags = info.data[5];
    if (major(version) > 4 or version & 0xff > 0) return null;
    if (info.size < read_size) return null;
    var w = Work{ .version = version, .flags = flags, .frame_data = info.data + HDR_SIZE };
    if (flags & FLAG_FOOTER != 0) {
        if (read_size < HDR_SIZE + 10) return null;
        w.frame_data_size = read_size - HDR_SIZE - 10;
    } else w.frame_data_size = read_size - HDR_SIZE;
    var uu: [*c]u8 = null;
    if (flags & FLAG_UNSYNC != 0 and major(version) <= 3) {
        uu = ununsync(w.frame_data, &w.frame_data_size);
        w.frame_data = uu;
    }
    framesToTagList(&w);
    c.g_free(uu);
    return w.tags;
}

fn isId(w: *Work, s: []const u8) bool {
    return c.strcmp(w.frame_id, s.ptr) == 0;
}

fn parseFrame(w: *Work) bool {
    var i: usize = 0;
    while (i < 5 and w.frame_id[i] != 0) : (i += 1) {
        if (!c.g_ascii_isalnum(w.frame_id[i])) return false;
    }
    if (w.frame_flags & F_ENCRYPTION != 0) return false;
    var tag_name = id3.gst_tag_from_id3_tag(w.frame_id);
    if (tag_name == null and c.strncmp(w.frame_id, "RVA2", 4) != 0 and c.strncmp(w.frame_id, "TXXX", 4) != 0 and c.strncmp(w.frame_id, "TDAT", 4) != 0 and c.strncmp(w.frame_id, "UFID", 4) != 0) return false;
    var data = w.frame_data;
    var size: u32 = w.cur_frame_size;
    if (w.frame_flags & (F_COMPRESSION | F_DLI) != 0) {
        if (size <= 4) return false;
        w.parse_size = if (major(w.version) == 3) be32(data) else synch(data);
        data += 4;
        size -= 4;
        if (w.parse_size > size) return false;
    }
    var uu: [*c]u8 = null;
    defer c.g_free(uu);
    if (major(w.version) == 4 and (w.flags & FLAG_UNSYNC != 0 or w.frame_flags & F_UNSYNC != 0)) {
        uu = ununsync(data, &size);
        data = uu;
    }
    w.parse_size = size;
    var uncompressed: [*c]u8 = null;
    if (w.frame_flags & F_COMPRESSION != 0) {
        var dest: c.uLongf = w.parse_size;
        uncompressed = @ptrCast(c.g_malloc(w.parse_size));
        if (c.uncompress(uncompressed, &dest, data, size) != c.Z_OK or dest != w.parse_size) {
            c.g_free(uncompressed);
            return false;
        }
        w.parse_data = uncompressed;
    } else w.parse_data = data;
    var result = false;
    var tag_str: [*c]u8 = null;
    var fields: ?*c.GArray = null;
    if (w.frame_id[0] == 'T') {
        if (isId(w, "TDAT")) {
            obsoleteTdat(w);
            result = true;
        } else if (isId(w, "TXXX")) {
            tag_str = userText(w, &tag_name);
        } else fields = textFrame(w);
    } else if (w.frame_id[0] == 'W' and !isId(w, "WXXX")) {
        tag_str = urlLink(w, &tag_name);
    } else if (isId(w, "COMM")) {
        result = comment(w);
    } else if (isId(w, "APIC")) {
        result = picture(w);
    } else if (isId(w, "RVA2")) {
        result = rva2(w);
    } else if (isId(w, "UFID")) {
        tag_str = ufid(w, &tag_name);
    } else if (isId(w, "PRIV")) result = private(w);
    if (w.frame_flags & F_COMPRESSION != 0) {
        c.g_free(uncompressed);
        w.parse_data = data;
    }
    if (tag_str != null) {
        result = toTagList(w, tag_name, tag_str);
        c.g_free(tag_str);
    }
    if (fields) |f| {
        if (isId(w, "TCON")) {
            result = genreFields(w, tag_name, f) or result;
        } else {
            for (0..f.len) |k| {
                const s = fieldAt(f, k);
                if (s != null and s[0] != 0) result = toTagList(w, tag_name, s) or result;
            }
        }
        freeFields(f);
    }
    return result;
}

fn fieldAt(f: *c.GArray, k: usize) [*c]u8 {
    const arr: [*c][*c]u8 = @ptrCast(@alignCast(f.data));
    return arr[k];
}

fn freeFields(f: ?*c.GArray) void {
    const a = f orelse return;
    for (0..a.len) |k| c.g_free(fieldAt(a, k));
    _ = c.g_array_free(a, 1);
}

fn comment(w: *Work) bool {
    if (w.parse_size < 6) return false;
    const enc = w.parse_data[0];
    var lang: [4]u8 = .{ c.g_ascii_tolower(w.parse_data[1]), c.g_ascii_tolower(w.parse_data[2]), c.g_ascii_tolower(w.parse_data[3]), 0 };
    var fields: ?*c.GArray = null;
    splitStrings(enc, w.parse_data + 4, @intCast(w.parse_size - 4), &fields);
    const f = fields orelse return false;
    defer freeFields(f);
    if (f.len < 2) return false;
    const desc = fieldAt(f, 0);
    const text = fieldAt(f, 1);
    if (c.g_utf8_validate(text, -1, null) == 0) return false;
    var dummy: c.guint = 0;
    if (c.strlen(desc) > 0 and c.g_utf8_validate(desc, -1, null) != 0 and c.sscanf(desc, "c%u", &dummy) != 1) {
        var s: [*c]u8 = null;
        if (lang[0] != 0 and c.g_ascii_isalpha(lang[0]) and c.g_ascii_isalpha(lang[1]) and (c.g_ascii_isalpha(lang[2]) or lang[2] == 0)) {
            const code = c.gst_tag_get_language_code_iso_639_1(&lang);
            s = c.g_strdup_printf("%s[%s]=%s", desc, if (code != null) code else @as([*c]const u8, &lang), text);
        } else s = c.g_strdup_printf("%s=%s", desc, text);
        c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, c.GST_TAG_EXTENDED_COMMENT, s, NONE);
        c.g_free(s);
    } else if (text != null and text[0] != 0) {
        c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, c.GST_TAG_COMMENT, text, NONE);
    } else return false;
    return true;
}

fn textFrame(w: *Work) ?*c.GArray {
    if (w.parse_size < 2) return null;
    var fields: ?*c.GArray = null;
    splitStrings(w.parse_data[0], w.parse_data + 1, @intCast(w.parse_size - 1), &fields);
    return fields;
}

fn urlLink(w: *Work, tag_name: *[*c]const u8) [*c]u8 {
    tag_name.* = null;
    if (w.parse_size == 0) return null;
    const nul = c.memchr(w.parse_data, 0, w.parse_size);
    const len: usize = if (nul != null) @intFromPtr(nul) - @intFromPtr(w.parse_data) else w.parse_size;
    const link = c.g_convert(w.parse_data, @intCast(len), "UTF-8", "ISO-8859-1", null, null, null);
    if (link == null or c.gst_uri_is_valid(link) == 0) {
        c.g_free(link);
        return null;
    }
    if (isId(w, "WCOP")) {
        tag_name.* = if (c.g_str_has_prefix(link, "http://creativecommons.org/licenses/") != 0) c.GST_TAG_LICENSE_URI else c.GST_TAG_COPYRIGHT_URI;
    } else if (isId(w, "WOAF")) tag_name.* = c.GST_TAG_CONTACT;
    return link;
}

fn userText(w: *Work, tag_name: *[*c]const u8) [*c]u8 {
    tag_name.* = null;
    if (w.parse_size < 2) return null;
    var fields: ?*c.GArray = null;
    splitStrings(w.parse_data[0], w.parse_data + 1, @intCast(w.parse_size - 1), &fields);
    const f = fields orelse return null;
    defer freeFields(f);
    if (f.len != 2) return null;
    tag_name.* = id3.gst_tag_from_id3_user_tag("TXXX", fieldAt(f, 0));
    return if (tag_name.* != null) c.g_strdup(fieldAt(f, 1)) else null;
}

fn idString(w: *Work, s: *[*c]u8, len_out: *c.gint, datalen_out: *c.gint) bool {
    if (w.parse_size < 2) return false;
    var len: c.gint = 0;
    while (len < @as(c.gint, @intCast(w.parse_size)) - 1) : (len += 1) {
        if (w.parse_data[@intCast(len)] == 0) break;
    }
    const datalen: c.gint = @as(c.gint, @intCast(w.parse_size)) - (len + 1);
    if (len == 0 or datalen <= 0) return false;
    s.* = c.g_strndup(w.parse_data, @intCast(len));
    len_out.* = len;
    datalen_out.* = datalen;
    return true;
}

fn private(w: *Work) bool {
    if (w.parse_size == 0) return false;
    const owner = c.memchr(w.parse_data, 0, w.parse_size);
    if (owner == null) return false;
    const olen: usize = @intFromPtr(owner) - @intFromPtr(w.parse_data) + 1;
    const info = c.gst_structure_new("ID3PrivateFrame", "owner", c.G_TYPE_STRING, w.parse_data, NONE);
    const bin = c.gst_buffer_new_allocate(null, w.parse_size - olen, null);
    _ = c.gst_buffer_fill(bin, 0, w.parse_data + olen, w.parse_size - olen);
    const sample = c.gst_sample_new(bin, null, null, info);
    c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, c.GST_TAG_PRIVATE_DATA, sample, NONE);
    c.gst_mini_object_unref(@ptrCast(@alignCast(sample)));
    c.gst_buffer_unref(bin);
    return true;
}

fn ufid(w: *Work, tag_name: *[*c]const u8) [*c]u8 {
    var owner: [*c]u8 = null;
    var len: c.gint = 0;
    var datalen: c.gint = 0;
    if (!idString(w, &owner, &len, &datalen)) return null;
    defer c.g_free(owner);
    const data = w.parse_data + @as(usize, @intCast(len)) + 1;
    if (c.strcmp(owner, "http://musicbrainz.org") == 0 and c.g_utf8_validate(data, datalen, null) != 0) {
        tag_name.* = c.GST_TAG_MUSICBRAINZ_TRACKID;
        return c.g_strndup(data, @intCast(datalen));
    }
    return null;
}

fn scanEncoded(enc: u8, data: [*c]const u8, size: c.gint) c.gint {
    var i: c.gint = 0;
    switch (enc) {
        ENC_ISO8859, ENC_UTF8 => while (i < size) : (i += 1) {
            if (data[@intCast(i)] == 0) return i + 1;
        },
        ENC_UTF16, ENC_UTF16BE => while (i < size - 1) : (i += 2) {
            if (data[@intCast(i)] == 0 and data[@intCast(i + 1)] == 0) return i + 2;
        },
        else => {},
    }
    return 0;
}

fn picture(w: *Work) bool {
    if (w.parse_size < 5) return false;
    const enc = w.parse_data[0];
    w.parse_data += 1;
    w.parse_size -= 1;
    var mime: [*c]u8 = null;
    defer c.g_free(mime);
    var len: c.gint = 0;
    if (major(w.version) < 3) {
        if (w.parse_size < 3) return false;
        mime = c.g_strndup(w.parse_data, 3);
        len = 3;
    } else {
        var datalen: c.gint = 0;
        if (!idString(w, &mime, &len, &datalen)) return false;
        len += 1;
    }
    if (@as(i64, w.parse_size) < len + 3) return false;
    w.parse_data += @intCast(len);
    w.parse_size -= @intCast(len);
    const pic_type = w.parse_data[0];
    w.parse_data += 1;
    w.parse_size -= 1;
    if (w.parse_size < 2) return false;
    len = scanEncoded(enc, w.parse_data, @intCast(w.parse_size));
    if (len < 1) return false;
    if (@as(i64, w.parse_size) < len + 1) return false;
    w.parse_data += @intCast(len);
    w.parse_size -= @intCast(len);
    if (w.parse_size <= 0) return false;
    return id3.gst_tag_list_add_id3_image(w.tags, w.parse_data, w.parse_size, pic_type) != 0;
}

fn rva2(w: *Work) bool {
    var id: [*c]u8 = null;
    var len: c.gint = 0;
    var datalen: c.gint = 0;
    if (!idString(w, &id, &len, &datalen)) return false;
    defer c.g_free(id);
    if (datalen < 4) return false;
    var data = w.parse_data + @as(usize, @intCast(len)) + 1;
    const chan = data[0];
    const gain_db = @as(f64, @floatFromInt(@as(i16, @bitCast(be16(data + 1))))) / 512.0;
    var peak_bits = data[3];
    if (peak_bits > 64) peak_bits = 0;
    data += 4;
    datalen -= 4;
    var peak: u64 = 0;
    if (peak_bits == 16) {
        peak = be16(data);
    } else {
        var i: c.gint = 0;
        const rounded = (@as(c.gint, peak_bits) + 7) & ~@as(c.gint, 7);
        while (i < @divTrunc(rounded, 8) and datalen > 0) : (i += 1) {
            peak = peak << 8 | data[0];
            data += 1;
            datalen -= 1;
        }
    }
    var peak_val: f64 = 0;
    if (peak_bits > 0) {
        const rounded: u7 = @intCast((@as(u32, peak_bits) + 7) & ~@as(u32, 7));
        peak = if (rounded >= 64) peak else peak << @intCast(64 - rounded);
        peak_val = @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(@as(u64, std.math.maxInt(i64))));
    }
    var gain_tag: [*c]const u8 = null;
    var peak_tag: [*c]const u8 = null;
    if (chan == 1 and c.strcmp(id, "track") == 0) {
        gain_tag = c.GST_TAG_TRACK_GAIN;
        peak_tag = c.GST_TAG_TRACK_PEAK;
    } else if (chan == 1 and c.strcmp(id, "album") == 0) {
        gain_tag = c.GST_TAG_ALBUM_GAIN;
        peak_tag = c.GST_TAG_ALBUM_PEAK;
    }
    if (gain_tag != null) c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, gain_tag, gain_db, NONE);
    if (peak_tag != null and peak_bits > 0) c.gst_tag_list_add(w.tags, c.GST_TAG_MERGE_APPEND, peak_tag, peak_val, NONE);
    return gain_tag != null or peak_tag != null;
}

fn obsoleteTdat(w: *Work) void {
    const d = w.parse_data;
    if (w.parse_size >= 5 and d[0] == ENC_ISO8859 and c.g_ascii_isdigit(d[1]) and c.g_ascii_isdigit(d[2]) and c.g_ascii_isdigit(d[3]) and c.g_ascii_isdigit(d[4])) {
        const day: c.guint = @intCast(10 * c.g_ascii_digit_value(d[1]) + c.g_ascii_digit_value(d[2]));
        const month: c.guint = @intCast(10 * c.g_ascii_digit_value(d[3]) + c.g_ascii_digit_value(d[4]));
        if (day >= 1 and day <= 31 and month >= 1 and month <= 12) {
            w.pending_day = day;
            w.pending_month = month;
        }
    }
}

fn toTagList(w: *Work, tag_name: [*c]const u8, tag_str: [*c]const u8) bool {
    const t = c.gst_tag_get_type(tag_name);
    const list = w.tags;
    if (tag_str == null) return false;
    if (t == c.G_TYPE_UINT) {
        var current: c.gint = 0;
        var total: c.gint = 0;
        if (c.sscanf(tag_str, "%d/%d", &current, &total) == 2) {
            if (total > 0) {
                if (c.strcmp(tag_name, c.GST_TAG_TRACK_NUMBER) == 0) {
                    c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, c.GST_TAG_TRACK_COUNT, total, NONE);
                } else if (c.strcmp(tag_name, c.GST_TAG_ALBUM_VOLUME_NUMBER) == 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, c.GST_TAG_ALBUM_VOLUME_COUNT, total, NONE);
            }
        } else if (c.sscanf(tag_str, "%d", &current) != 1) return true;
        if (current > 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, tag_name, current, NONE);
    } else if (t == c.G_TYPE_UINT64) {
        const tmp: u64 = c.strtoul(tag_str, null, 10);
        if (tmp != 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, c.GST_TAG_DURATION, tmp *% 1000 *% 1000, NONE);
    } else if (t == c.G_TYPE_STRING) {
        const num = c.gst_tag_list_get_tag_size(list, tag_name);
        var i: c.guint = 0;
        while (i < num) : (i += 1) {
            const v = c.gst_tag_list_get_value_index(list, tag_name, i);
            if (v != null and c.strcmp(c.g_value_get_string(v), tag_str) == 0) break;
        }
        if (i == num) c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, tag_name, tag_str, NONE);
    } else if (t == c.gst_date_time_get_type()) {
        const dt = c.gst_date_time_new_from_iso8601_string(tag_str);
        if (dt != null) {
            c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, tag_name, dt, NONE);
            c.gst_date_time_unref(dt);
        }
    } else {
        var src = std.mem.zeroes(c.GValue);
        var dest = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&src, c.G_TYPE_STRING);
        c.g_value_set_string(&src, tag_str);
        _ = c.g_value_init(&dest, t);
        if (c.g_value_transform(&src, &dest) != 0) {
            c.gst_tag_list_add_values(list, c.GST_TAG_MERGE_APPEND, tag_name, &dest, NONE);
        } else if (t == c.G_TYPE_DOUBLE) {
            c.g_value_set_double(&dest, c.g_strtod(tag_str, null));
            c.gst_tag_list_add_values(list, c.GST_TAG_MERGE_KEEP, tag_name, &dest, NONE);
        }
        c.g_value_unset(&src);
        c.g_value_unset(&dest);
    }
    return true;
}

fn allDigits(s: [*c]const u8, len: c.gint) bool {
    var i: c.gint = 0;
    while (i < len) : (i += 1) {
        if (!c.g_ascii_isdigit(s[@intCast(i)])) return false;
    }
    return true;
}

fn genreString(w: *Work, tag_name: [*c]const u8, s: [*c]const u8, len: c.gint) bool {
    if (!check.that(s != null, "id3v2_genre_string_to_taglist", "tag_str != NULL")) return false;
    if (allDigits(s, len)) return toTagList(w, tag_name, id3.gst_tag_id3_genre_get(@truncate(@as(c_ulong, @bitCast(c.strtol(s, null, 10))))));
    if (len == 2) {
        if (c.g_ascii_strncasecmp("rx", s, 2) == 0) return toTagList(w, tag_name, "Remix");
        if (c.g_ascii_strncasecmp("cr", s, 2) == 0) return toTagList(w, tag_name, "Cover");
    }
    return toTagList(w, tag_name, s);
}

fn genreFields(w: *Work, tag_name: [*c]const u8, f: *c.GArray) bool {
    var result = false;
    for (0..f.len) |k| {
        var s: [*c]const u8 = fieldAt(f, k);
        if (s == null) continue;
        var len: c.gint = @intCast(c.strlen(s));
        while (len >= 2) {
            if (s[0] == '(' and s[1] == '(') {
                s += 1;
                len -= 1;
                break;
            }
            if (s[0] != '(') break;
            var found = false;
            var pos: c.gint = 1;
            while (pos < len) : (pos += 1) {
                if (s[@intCast(pos)] == ')') {
                    const tmp = c.g_strndup(s + 1, @intCast(pos - 1));
                    result = genreString(w, tag_name, tmp, pos - 1) or result;
                    c.g_free(tmp);
                    s += @intCast(pos + 1);
                    len -= pos + 1;
                    found = true;
                    break;
                }
                if (!c.g_ascii_isdigit(s[@intCast(pos)])) break;
            }
            if (!found) break;
        }
        if (len > 0 and s != null) result = genreString(w, tag_name, s, len) or result;
    }
    return result;
}

fn bom(data: [*c]const u8, little: *bool) bool {
    const m = @as(u16, data[0]) << 8 | data[1];
    if (m == 0xFFFE) {
        little.* = true;
        return true;
    }
    if (m == 0xFEFF) {
        little.* = false;
        return true;
    }
    return false;
}

fn utf8Dup(start: [*c]const u8, size: c.guint) [*c]u8 {
    var utf8: [*c]u8 = null;
    found: {
        if (c.g_utf8_validate(start, size, null) != 0) {
            utf8 = c.g_strndup(start, size);
            break :found;
        }
        var env = c.g_getenv("GST_ID3V1_TAG_ENCODING");
        if (env == null or env[0] == 0) env = c.g_getenv("GST_ID3_TAG_ENCODING");
        if (env == null or env[0] == 0) env = c.g_getenv("GST_TAG_ENCODING");
        var read: usize = 0;
        if (env != null and env[0] != 0) {
            const sets = c.g_strsplit(env, ":", -1);
            var p = sets;
            while (p != null and p[0] != null) : (p += 1) {
                utf8 = c.g_convert(start, size, "UTF-8", p[0], &read, null, null);
                if (utf8 != null) {
                    if (read == size) {
                        c.g_strfreev(sets);
                        break :found;
                    }
                    c.g_free(utf8);
                    utf8 = null;
                }
            }
            c.g_strfreev(sets);
        }
        var cs: [*c]const u8 = null;
        if (c.g_get_charset(&cs) == 0) {
            utf8 = c.g_locale_to_utf8(start, size, &read, null, null);
            if (utf8 != null) {
                if (read == size) break :found;
                c.g_free(utf8);
                utf8 = null;
            }
        }
        utf8 = c.g_convert(start, size, "UTF-8", "ISO-8859-1", &read, null, null);
        if (utf8 != null and read == size) break :found;
        c.g_free(utf8);
        return null;
    }
    _ = c.g_strchomp(utf8);
    return utf8;
}

fn insertField(enc: u8, data_in: [*c]const u8, size_in: c.gint, fields: *c.GArray) void {
    var field: [*c]u8 = null;
    var data = data_in;
    var size = size_in;
    switch (enc) {
        ENC_UTF16, ENC_UTF16BE => blk: {
            var little = if (enc == ENC_UTF16) @import("builtin").cpu.arch.endian() == .little else false;
            while (size >= 2 and bom(data, &little)) {
                data += 2;
                size -= 2;
            }
            if (size < 2) {
                field = c.g_strdup("");
                break :blk;
            }
            const len: usize = @intCast(@divTrunc(size, 2));
            const utf16: [*c]u16 = @ptrCast(@alignCast(c.g_try_malloc(@sizeOf(u16) * (len + 1))));
            if (utf16 == null) break :blk;
            @memcpy(@as([*]u8, @ptrCast(utf16))[0 .. 2 * len], data[0 .. 2 * len]);
            const native_little = @import("builtin").cpu.arch.endian() == .little;
            if (little != native_little) {
                for (0..len) |i| utf16[i] = @byteSwap(utf16[i]);
            }
            var n_read: c.glong = 0;
            var n_size: c.glong = 0;
            field = c.g_utf16_to_utf8(utf16, @intCast(len), &n_read, &n_size, null);
            if (field != null and n_read > 0 and c.g_utf8_validate(field, -1, null) != 0) {
                c.g_free(utf16);
                break :blk;
            }
            for (0..len) |i| utf16[i] = @byteSwap(utf16[i]);
            c.g_free(field);
            n_read = 0;
            n_size = 0;
            field = c.g_utf16_to_utf8(utf16, @intCast(len), &n_read, &n_size, null);
            c.g_free(utf16);
            if (field != null and n_read > 0 and c.g_utf8_validate(field, -1, null) != 0) break :blk;
            c.g_free(field);
            field = null;
        },
        ENC_ISO8859 => field = if (c.g_utf8_validate(data, size, null) != 0) c.g_strndup(data, @intCast(size)) else utf8Dup(data, @intCast(size)),
        else => field = c.g_strndup(data, @intCast(size)),
    }
    if (field == null) return;
    if (c.g_utf8_validate(field, -1, null) != 0) {
        _ = c.g_array_append_vals(fields, @ptrCast(&field), 1);
        return;
    }
    c.g_free(field);
}

fn splitStrings(enc: u8, data: [*c]const u8, size: c.gint, out: *?*c.GArray) void {
    const fields: *c.GArray = c.g_array_new(0, 1, @sizeOf([*c]u8));
    var prev: c.gint = 0;
    var pos: c.gint = 0;
    switch (enc) {
        ENC_ISO8859, ENC_UTF8 => {
            while (pos < size) : (pos += 1) {
                if (data[@intCast(pos)] == 0) {
                    insertField(enc, data + @as(usize, @intCast(prev)), pos - prev, fields);
                    prev = pos + 1;
                }
            }
            if (size - prev > 0 and data[@intCast(prev)] != 0) insertField(enc, data + @as(usize, @intCast(prev)), size - prev, fields);
        },
        ENC_UTF16, ENC_UTF16BE => {
            while (pos < size - 1) : (pos += 2) {
                if (data[@intCast(pos)] == 0 and data[@intCast(pos + 1)] == 0) {
                    insertField(enc, data + @as(usize, @intCast(prev)), pos - prev, fields);
                    prev = pos + 2;
                }
            }
            if (size - prev > 1 and (data[@intCast(prev)] != 0 or data[@intCast(prev + 1)] != 0)) insertField(enc, data + @as(usize, @intCast(prev)), size - prev, fields);
        },
        else => {},
    }
    if (fields.len > 0) out.* = fields else _ = c.g_array_free(fields, 1);
}
