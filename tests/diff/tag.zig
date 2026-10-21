const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [16384]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const NONE = @as(?*anyopaque, null);

fn showList(label: []const u8, l: [*c]const c.GstTagList) void {
    if (l == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_tag_list_to_string(l);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
}

fn enumDump(gt: c.GType) void {
    const k = c.g_type_class_ref(gt);
    defer c.g_type_class_unref(k);
    out("enum {s} fund={d}", .{ str(c.g_type_name(gt)), c.g_type_fundamental(gt) });
}

const PNG = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0x0d, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xde, 0, 0, 0, 0x0c, 'I', 'D', 'A', 'T', 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0, 0, 0x03, 0x01, 0x01, 0, 0x18, 0xdd, 0x8d, 0xb0, 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82 };

fn sampleInfo(s: ?*c.GstSample) void {
    if (s == null) {
        out("  sample (null)", .{});
        return;
    }
    const caps = c.gst_sample_get_caps(s);
    const cs = c.gst_caps_to_string(caps);
    const info = c.gst_sample_get_info(s);
    const is = if (info != null) c.gst_structure_to_string(info) else c.g_strdup("(none)");
    out("  sample size={d} caps={s} info={s}", .{ c.gst_buffer_get_size(c.gst_sample_get_buffer(s)), str(cs), str(is) });
    c.g_free(cs);
    c.g_free(is);
}

fn hex(b: [*c]c.GstBuffer) void {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &info);
    var line: [4096]u8 = undefined;
    var n: usize = 0;
    for (0..@min(info.size, 1500)) |i| {
        const ch = info.data[i];
        if (ch >= 0x20 and ch < 0x7f) {
            line[n] = ch;
            n += 1;
        } else {
            _ = std.fmt.bufPrint(line[n..], "\\{x:0>2}", .{ch}) catch break;
            n += 3;
        }
        if (n > line.len - 8) break;
    }
    out("  bytes {d} [{s}]", .{ info.size, line[0..n] });
}

fn langs() void {
    out("== lang", .{});
    const codes = c.gst_tag_get_language_codes();
    var n: usize = 0;
    var joined = std.ArrayList(u8).empty;
    while (codes[n] != null) : (n += 1) {
        joined.appendSlice(std.heap.c_allocator, std.mem.span(codes[n])) catch {};
        joined.append(std.heap.c_allocator, ' ') catch {};
    }
    out("  codes {d} {s}", .{ n, joined.items });
    c.g_strfreev(codes);
    var count: usize = 0;
    var sum: u64 = 0;
    var code: [4]u8 = .{ 0, 0, 0, 0 };
    for (0..26) |i| for (0..26) |j| for (0..27) |k| {
        code = .{ @intCast('a' + i), @intCast('a' + j), if (k == 26) 0 else @intCast('a' + k), 0 };
        const name = c.gst_tag_get_language_name(&code);
        const c1 = c.gst_tag_get_language_code_iso_639_1(&code);
        const t = c.gst_tag_get_language_code_iso_639_2T(&code);
        const b = c.gst_tag_get_language_code_iso_639_2B(&code);
        if (name == null and c1 == null and t == null and b == null) continue;
        count += 1;
        var h = std.hash.Fnv1a_64.init();
        h.update(&code);
        h.update(str(name));
        h.update(str(c1));
        h.update(str(t));
        h.update(str(b));
        h.update(if (c.gst_tag_check_language_code(&code) != 0) "y" else "n");
        sum +%= h.final();
    };
    out("  known {d} hash {x}", .{ count, sum });
    for ([_][*c]const u8{ "", "de", "deu", "ger", "DE", "deu ", "x", "fr", "fre", "fra", "zh", "chi", "zho", "nb", "nob", "qaa", "tlh", "zza" }) |s| {
        out("  [{s}] name={s} 1={s} 2T={s} 2B={s} check={d}", .{ str(s), str(c.gst_tag_get_language_name(s)), str(c.gst_tag_get_language_code_iso_639_1(s)), str(c.gst_tag_get_language_code_iso_639_2T(s)), str(c.gst_tag_get_language_code_iso_639_2B(s)), c.gst_tag_check_language_code(s) });
    }
}

fn licenseInfo(r: [*c]const u8) void {
    out("  {s} flags={x} nick={s} title={s} desc={s} jur={s} ver={s}", .{ str(r), c.gst_tag_get_license_flags(r), str(c.gst_tag_get_license_nick(r)), str(c.gst_tag_get_license_title(r)), str(c.gst_tag_get_license_description(r)), str(c.gst_tag_get_license_jurisdiction(r)), str(c.gst_tag_get_license_version(r)) });
}

fn licenses() void {
    out("== licenses", .{});
    const refs = c.gst_tag_get_licenses();
    var i: usize = 0;
    while (refs[i] != null) : (i += 1) licenseInfo(refs[i]);
    c.g_strfreev(refs);
    for ([_][*c]const u8{ "http://creativecommons.org/licenses/by/2.0", "http://creativecommons.org/licenses/by/2.0/de", "http://creativecommons.org/licenses/by/2.0/de/extra", "http://creativecommons.org/licenses/by-nd-nc/2.0/jp/", "http://creativecommons.org/licenses/by/9.0/", "http://example.com/licenses/by/2.0/", "http://creativecommons.org/licenses/", "http://creativecommons.org/licenses/publicdomain/", "http://creativecommons.org/licenses/GPL/2.0", "http://creativecommons.org/licenses/by/3.0/us/" }) |r| licenseInfo(r);
}

fn tagInfo(name: [*c]const u8) void {
    out("  tag {s} exists={d} type={s} nick={s} desc={s} flag={d} fixed={d}", .{ str(name), c.gst_tag_exists(name), str(c.g_type_name(c.gst_tag_get_type(name))), str(c.gst_tag_get_nick(name)), str(c.gst_tag_get_description(name)), c.gst_tag_get_flag(name), c.gst_tag_is_fixed(name) });
}

fn id3() void {
    out("== id3", .{});
    for ([_][*c]const u8{ "TIT2", "TALB", "TRCK", "TPE1", "TPE2", "TCOM", "TPE3", "TCOP", "WCOP", "TENC", "TCON", "TDRC", "COMM", "TPOS", "TLEN", "TSRC", "APIC", "TSSE", "TBPM", "TSOP", "TSOA", "TSOT", "TPUB", "TPE4", "TKEY", "PRIV", "TIT2X", "XXXX", "TIT" }) |t| out("  from {s} -> {s}", .{ str(t), str(c.gst_tag_from_id3_tag(t)) });
    for ([_][*c]const u8{ "title", "album", "artist", "comment", "image", "nonexistent", "private-data", "musical-key" }) |t| out("  to {s} -> {s}", .{ str(t), str(c.gst_tag_to_id3_tag(t)) });
    for ([_][*c]const u8{ "musicbrainz_trackid", "MUSICBRAINZ_TRACKID", "MusicBrainz Album Id", "replaygain_track_gain", "discid", "CDDB DiscID", "unknown" }) |u| out("  user TXXX {s} -> {s}", .{ str(u), str(c.gst_tag_from_id3_user_tag("TXXX", u)) });
    out("  user WXXX -> {s}", .{str(c.gst_tag_from_id3_user_tag("WXXX", "discid"))});
    out("  genres {d}", .{c.gst_tag_id3_genre_count()});
    var g: c.guint = 0;
    while (g <= c.gst_tag_id3_genre_count()) : (g += 1) out("    {d} {s}", .{ g, str(c.gst_tag_id3_genre_get(g)) });
    var v1 = std.mem.zeroes([128]u8);
    @memcpy(v1[0..3], "TAG");
    @memcpy(v1[3..12], "Song Name");
    @memcpy(v1[33..39], "Artist");
    @memcpy(v1[63..72], "Caf\xe9 Song");
    @memcpy(v1[93..97], "1999");
    @memcpy(v1[97..104], "Comment");
    v1[126] = 7;
    v1[127] = 17;
    const l = c.gst_tag_list_new_from_id3v1(&v1);
    showList("v1", l);
    c.gst_tag_list_unref(l);
    v1[125] = 'x';
    v1[127] = 200;
    const l2 = c.gst_tag_list_new_from_id3v1(&v1);
    showList("v1b", l2);
    c.gst_tag_list_unref(l2);
    var empty = std.mem.zeroes([128]u8);
    @memcpy(empty[0..3], "TAG");
    empty[127] = 3;
    const l3 = c.gst_tag_list_new_from_id3v1(&empty);
    showList("v1 empty", l3);
    c.gst_tag_list_unref(l3);
    out("  v1 notag null {d}", .{@intFromBool(c.gst_tag_list_new_from_id3v1("XYZ") == null)});
    const il = c.gst_tag_list_new_empty();
    for ([_]c.guint{ 0, 1, 2, 3, 0x14, 0x15 }) |pt| out("  add image {d} -> {d}", .{ pt, c.gst_tag_list_add_id3_image(il, &PNG, PNG.len, pt) });
    var idx: c.guint = 0;
    while (idx < c.gst_tag_list_get_tag_size(il, c.GST_TAG_IMAGE)) : (idx += 1) {
        var s: ?*c.GstSample = null;
        _ = c.gst_tag_list_get_sample_index(il, c.GST_TAG_IMAGE, idx, &s);
        sampleInfo(s);
        c.gst_mini_object_unref(@ptrCast(@alignCast(s)));
    }
    out("  preview count {d}", .{c.gst_tag_list_get_tag_size(il, c.GST_TAG_PREVIEW_IMAGE)});
    c.gst_tag_list_unref(il);
    out("  junk image null {d}", .{@intFromBool(c.gst_tag_image_data_to_image_sample("garbage-bytes", 13, c.GST_TAG_IMAGE_TYPE_NONE) == null)});
    sampleInfo(c.gst_tag_image_data_to_image_sample("http://example.com/x.png\r\n", 26, c.GST_TAG_IMAGE_TYPE_FRONT_COVER));
}

fn vorbis() void {
    out("== vorbis", .{});
    for ([_][*c]const u8{ "title", "TrackNumber", "license", "album artist", "musicbrainz_sortname", "encoder", "bogus" }) |t| out("  from {s} -> {s}", .{ str(t), str(c.gst_tag_from_vorbis_tag(t)) });
    for ([_][*c]const u8{ "title", "license", "license-uri", "artist-sortname", "track-count", "image", "preview-image", "nothing" }) |t| out("  to {s} -> {s}", .{ str(t), str(c.gst_tag_to_vorbis_tag(t)) });
    const l = c.gst_tag_list_new_empty();
    const pairs = [_][2][*c]const u8{ .{ "TITLE", "A Title" }, .{ "TRACKNUMBER", "3/12" }, .{ "DISCNUMBER", "2/0" }, .{ "TRACKNUMBER", "4x" }, .{ "LANGUAGE", "English [eng]" }, .{ "LANGUAGE", "Deutsch [de]" }, .{ "LANGUAGE", "fr" }, .{ "LICENSE", "http://creativecommons.org/licenses/by/3.0/" }, .{ "LICENSE", "All rights" }, .{ "REPLAYGAIN_TRACK_GAIN", "-6,5 dB" }, .{ "R128_TRACK_GAIN", "-512" }, .{ "R128_ALBUM_GAIN", "99999" }, .{ "DATE", "2010-02-03" }, .{ "DATE", "garbage" }, .{ "CUSTOM", "value" }, .{ "BPM", "120.5" }, .{ "ALBUM ARTIST", "AA" } };
    for (pairs) |p| c.gst_vorbis_tag_add(l, p[0], p[1]);
    showList("added", l);
    const buf = c.gst_tag_list_to_vorbiscomment_buffer(l, "\x03vorbis", 7, null);
    hex(buf);
    var vendor: [*c]u8 = null;
    const back = c.gst_tag_list_from_vorbiscomment_buffer(buf, "\x03vorbis", 7, &vendor);
    showList("back", back);
    out("  vendor {s}", .{str(vendor)});
    c.g_free(vendor);
    if (back != null) c.gst_tag_list_unref(back);
    const wrong = c.gst_tag_list_from_vorbiscomment_buffer(buf, "\x03theora", 7, null);
    out("  wrong id null {d}", .{@intFromBool(wrong == null)});
    c.gst_buffer_unref(buf);
    var lst = c.gst_tag_to_vorbis_comments(l, c.GST_TAG_TRACK_NUMBER);
    var it: ?*c.GList = lst;
    while (it) |n| : (it = n.next) out("  comment {s}", .{str(@ptrCast(n.data))});
    c.g_list_free_full(lst, c.g_free);
    lst = c.gst_tag_to_vorbis_comments(l, c.GST_TAG_EXTENDED_COMMENT);
    it = lst;
    while (it) |n| : (it = n.next) out("  ext {s}", .{str(@ptrCast(n.data))});
    c.g_list_free_full(lst, c.g_free);
    const il = c.gst_tag_list_new_empty();
    _ = c.gst_tag_list_add_id3_image(il, &PNG, PNG.len, 3);
    lst = c.gst_tag_to_vorbis_comments(il, c.GST_TAG_IMAGE);
    it = lst;
    while (it) |n| : (it = n.next) out("  pic {s}", .{str(@ptrCast(n.data))});
    c.g_list_free_full(lst, c.g_free);
    const pb = c.gst_tag_list_to_vorbiscomment_buffer(il, null, 0, "vendor");
    const pl = c.gst_tag_list_from_vorbiscomment_buffer(pb, null, 0, null);
    out("  pic roundtrip images {d}", .{c.gst_tag_list_get_tag_size(pl, c.GST_TAG_IMAGE)});
    c.gst_tag_list_unref(pl);
    c.gst_buffer_unref(pb);
    c.gst_tag_list_unref(il);
    c.gst_tag_list_unref(l);
    const short = c.gst_tag_list_from_vorbiscomment("abc", 3, null, 0, null);
    out("  short null {d}", .{@intFromBool(short == null)});
}

pub fn main() void {
    c.gst_init(null, null);
    enumDump(c.gst_tag_image_type_get_type());
    enumDump(c.gst_tag_license_flags_get_type());
    enumDump(c.gst_tag_demux_result_get_type());
    tagInfo("musicbrainz-trackid");
    c.gst_tag_register_musicbrainz_tags();
    c.gst_tag_register_musicbrainz_tags();
    for ([_][*c]const u8{ "musicbrainz-trackid", "musicbrainz-artistid", "musicbrainz-albumid", "musicbrainz-albumartistid", "musicbrainz-releasegroupid", "musicbrainz-releasetrackid", "musicbrainz-trmid", "acoustid-id", "acoustid-fingerprint", "discid", "discid-full", "musicbrainz-discid", "musicbrainz-discid-full", "capturing-shutter-speed", "capturing-focal-ratio", "capturing-focal-length", "capturing-focal-length-35mm", "capturing-digital-zoom-ratio", "capturing-iso-speed", "capturing-exposure-program", "capturing-exposure-mode", "capturing-exposure-compensation", "capturing-scene-capture-type", "capturing-gain-adjustment", "capturing-white-balance", "capturing-light-source", "capturing-contrast", "capturing-saturation", "capturing-sharpness", "capturing-flash-fired", "capturing-flash-mode", "capturing-metering-mode", "capturing-source", "image-horizontal-ppi", "image-vertical-ppi", "private-id3v2-frame", "musical-key" }) |t| tagInfo(t);
    out("== extended", .{});
    for ([_][*c]const u8{ "key=value", "key[en]=value", "noequals", "k[e=v", "k]x[y=v", "=empty", "a[b]c=d" }) |e| {
        for ([_]c.gboolean{ 0, 1 }) |f| {
            var k: [*c]u8 = null;
            var lg: [*c]u8 = null;
            var v: [*c]u8 = null;
            const r = c.gst_tag_parse_extended_comment(e, &k, &lg, &v, f);
            out("  {s} fail={d} -> {d} key={s} lang={s} value={s}", .{ str(e), f, r, str(k), str(lg), str(v) });
            c.g_free(k);
            c.g_free(lg);
            c.g_free(v);
        }
    }
    out("== freeform", .{});
    var env = [_][*c]const u8{ "SINTY_TEST_ENC", null };
    _ = c.g_setenv("SINTY_TEST_ENC", "KOI8-R:ISO-8859-2", 1);
    const samples = [_][]const u8{ "plain ascii  ", "caf\xc3\xa9", "caf\xe9", "\xfe\xff\x00h\x00i", "\xff\xfeh\x00i\x00", "\x00\x00\xfe\xff\x00\x00\x00A", "   ", "trail\x00\x00", "\xc1\xe2\xd3" };
    for (samples) |s| {
        const r = c.gst_tag_freeform_string_to_utf8(s.ptr, @intCast(s.len), &env);
        var h: [64]u8 = undefined;
        var n: usize = 0;
        if (r != null) for (std.mem.span(r)) |ch| {
            _ = std.fmt.bufPrint(h[n..], "{x:0>2}", .{ch}) catch break;
            n += 2;
        };
        out("  len={d} -> {s} [{s}]", .{ s.len, if (r == null) "(null)" else "ok", h[0..n] });
        c.g_free(r);
    }
    langs();
    licenses();
    id3();
    vorbis();
    out("== crit", .{});
    _ = c.gst_tag_parse_extended_comment(null, null, null, null, 0);
    _ = c.gst_tag_parse_extended_comment("\xff\xfe=", null, null, null, 0);
    _ = c.gst_tag_freeform_string_to_utf8(null, 0, null);
    _ = c.gst_tag_image_data_to_image_sample(null, 1, 0);
    _ = c.gst_tag_image_data_to_image_sample("x", 0, 0);
    _ = c.gst_tag_image_data_to_image_sample("x", 1, 99);
    _ = c.gst_tag_get_language_name(null);
    _ = c.gst_tag_get_license_flags(null);
    _ = c.gst_tag_from_id3_tag(null);
    _ = c.gst_tag_from_id3_user_tag("TXX", "a");
    _ = c.gst_tag_list_add_id3_image(null, null, 0, 0);
    c.gst_vorbis_tag_add(null, "a", "b");
    const l = c.gst_tag_list_new_empty();
    c.gst_vorbis_tag_add(l, "A=B", "b");
    c.gst_tag_list_unref(l);
    _ = c.gst_tag_list_to_vorbiscomment_buffer(null, null, 0, null);
    _ = c.gst_tag_list_from_vorbiscomment("x", 1, null, 3, null);
    out("done", .{});
}
