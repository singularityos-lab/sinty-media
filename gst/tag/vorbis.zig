const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tags = @import("tags.zig");
const id3 = @import("id3.zig");
const enums = @import("enumtypes.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Match = id3.Match;

const MATCHES = [_]Match{
    .{ .gst = c.GST_TAG_TITLE, .orig = "TITLE" },
    .{ .gst = c.GST_TAG_VERSION, .orig = "VERSION" },
    .{ .gst = c.GST_TAG_ALBUM, .orig = "ALBUM" },
    .{ .gst = c.GST_TAG_TRACK_NUMBER, .orig = "TRACKNUMBER" },
    .{ .gst = c.GST_TAG_ALBUM_VOLUME_NUMBER, .orig = "DISCNUMBER" },
    .{ .gst = c.GST_TAG_TRACK_COUNT, .orig = "TRACKTOTAL" },
    .{ .gst = c.GST_TAG_TRACK_COUNT, .orig = "TOTALTRACKS" },
    .{ .gst = c.GST_TAG_ALBUM_VOLUME_COUNT, .orig = "DISCTOTAL" },
    .{ .gst = c.GST_TAG_ALBUM_VOLUME_COUNT, .orig = "TOTALDISCS" },
    .{ .gst = c.GST_TAG_ARTIST, .orig = "ARTIST" },
    .{ .gst = c.GST_TAG_PERFORMER, .orig = "PERFORMER" },
    .{ .gst = c.GST_TAG_COMPOSER, .orig = "COMPOSER" },
    .{ .gst = c.GST_TAG_COPYRIGHT, .orig = "COPYRIGHT" },
    .{ .gst = c.GST_TAG_LICENSE, .orig = "LICENSE" },
    .{ .gst = c.GST_TAG_LICENSE_URI, .orig = "LICENSE" },
    .{ .gst = c.GST_TAG_GEO_LOCATION_NAME, .orig = "LOCATION" },
    .{ .gst = c.GST_TAG_ORGANIZATION, .orig = "ORGANIZATION" },
    .{ .gst = c.GST_TAG_DESCRIPTION, .orig = "DESCRIPTION" },
    .{ .gst = c.GST_TAG_GENRE, .orig = "GENRE" },
    .{ .gst = c.GST_TAG_DATE_TIME, .orig = "DATE" },
    .{ .gst = c.GST_TAG_CONTACT, .orig = "CONTACT" },
    .{ .gst = c.GST_TAG_ISRC, .orig = "ISRC" },
    .{ .gst = c.GST_TAG_COMMENT, .orig = "COMMENT" },
    .{ .gst = c.GST_TAG_TRACK_GAIN, .orig = "REPLAYGAIN_TRACK_GAIN" },
    .{ .gst = c.GST_TAG_TRACK_GAIN_R128, .orig = "R128_TRACK_GAIN" },
    .{ .gst = c.GST_TAG_TRACK_PEAK, .orig = "REPLAYGAIN_TRACK_PEAK" },
    .{ .gst = c.GST_TAG_ALBUM_GAIN, .orig = "REPLAYGAIN_ALBUM_GAIN" },
    .{ .gst = c.GST_TAG_ALBUM_GAIN_R128, .orig = "R128_ALBUM_GAIN" },
    .{ .gst = c.GST_TAG_ALBUM_PEAK, .orig = "REPLAYGAIN_ALBUM_PEAK" },
    .{ .gst = c.GST_TAG_REFERENCE_LEVEL, .orig = "REPLAYGAIN_REFERENCE_LOUDNESS" },
    .{ .gst = c.GST_TAG_ACOUSTID_ID, .orig = "ACOUSTID_ID" },
    .{ .gst = c.GST_TAG_ACOUSTID_FINGERPRINT, .orig = "ACOUSTID_FINGERPRINT" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_TRACKID, .orig = "MUSICBRAINZ_TRACKID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASETRACKID, .orig = "MUSICBRAINZ_RELEASETRACKID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ARTISTID, .orig = "MUSICBRAINZ_ARTISTID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMID, .orig = "MUSICBRAINZ_ALBUMID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMARTISTID, .orig = "MUSICBRAINZ_ALBUMARTISTID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASEGROUPID, .orig = "MUSICBRAINZ_RELEASEGROUPID" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_TRMID, .orig = "MUSICBRAINZ_TRMID" },
    .{ .gst = c.GST_TAG_ARTIST_SORTNAME, .orig = "ARTISTSORT" },
    .{ .gst = c.GST_TAG_ARTIST_SORTNAME, .orig = "ARTISTSORTORDER" },
    .{ .gst = c.GST_TAG_ARTIST_SORTNAME, .orig = "MUSICBRAINZ_SORTNAME" },
    .{ .gst = c.GST_TAG_ALBUM_SORTNAME, .orig = "ALBUMSORT" },
    .{ .gst = c.GST_TAG_ALBUM_SORTNAME, .orig = "ALBUMSORTORDER" },
    .{ .gst = c.GST_TAG_TITLE_SORTNAME, .orig = "TITLESORT" },
    .{ .gst = c.GST_TAG_TITLE_SORTNAME, .orig = "TITLESORTORDER" },
    .{ .gst = c.GST_TAG_ALBUM_ARTIST, .orig = "ALBUMARTIST" },
    .{ .gst = c.GST_TAG_ALBUM_ARTIST, .orig = "ALBUM ARTIST" },
    .{ .gst = c.GST_TAG_ALBUM_ARTIST_SORTNAME, .orig = "ALBUMARTISTSORT" },
    .{ .gst = c.GST_TAG_ALBUM_ARTIST_SORTNAME, .orig = "ALBUMARTISTSORTORDER" },
    .{ .gst = c.GST_TAG_LANGUAGE_CODE, .orig = "LANGUAGE" },
    .{ .gst = c.GST_TAG_LYRICS, .orig = "LYRICS" },
    .{ .gst = c.GST_TAG_CDDA_MUSICBRAINZ_DISCID, .orig = "MUSICBRAINZ_DISCID" },
    .{ .gst = c.GST_TAG_CDDA_CDDB_DISCID, .orig = "DISCID" },
    .{ .gst = c.GST_TAG_PREVIEW_IMAGE, .orig = "COVERART" },
    .{ .gst = c.GST_TAG_BEATS_PER_MINUTE, .orig = "BPM" },
    .{ .gst = c.GST_TAG_APPLICATION_NAME, .orig = "ENCODER" },
};

const NONE = @as(?*anyopaque, null);

pub export fn gst_tag_from_vorbis_tag(vorbis_tag: [*c]const u8) [*c]const u8 {
    if (!check.that(vorbis_tag != null, "gst_tag_from_vorbis_tag", "vorbis_tag != NULL")) return null;
    tags.gst_tag_register_musicbrainz_tags();
    const up = c.g_ascii_strup(vorbis_tag, -1);
    defer c.g_free(up);
    for (MATCHES) |m| {
        if (c.strcmp(up, m.orig) == 0) return m.gst;
    }
    return null;
}

pub export fn gst_tag_to_vorbis_tag(tag: [*c]const u8) [*c]const u8 {
    if (!check.that(tag != null, "gst_tag_to_vorbis_tag", "gst_tag != NULL")) return null;
    tags.gst_tag_register_musicbrainz_tags();
    for (MATCHES) |m| {
        if (c.strcmp(tag, m.gst) == 0) return m.orig;
    }
    return null;
}

pub export fn gst_vorbis_tag_add(list: [*c]c.GstTagList, tag: [*c]const u8, value: [*c]const u8) void {
    const fname = "gst_vorbis_tag_add";
    if (!check.that(list != null, fname, "list != NULL")) return;
    if (!check.that(tag != null, fname, "tag != NULL")) return;
    if (!check.that(value != null, fname, "value != NULL")) return;
    if (!check.that(c.g_utf8_validate(tag, -1, null) != 0, fname, "g_utf8_validate (tag, -1, NULL)")) return;
    if (!check.that(c.g_utf8_validate(value, -1, null) != 0, fname, "g_utf8_validate (value, -1, NULL)")) return;
    if (!check.that(c.strchr(tag, '=') == null, fname, "strchr (tag, '=') == NULL")) return;
    var gst_tag = gst_tag_from_vorbis_tag(tag);
    if (gst_tag == null) {
        const ext = c.g_strdup_printf("%s=%s", tag, value);
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, c.GST_TAG_EXTENDED_COMMENT, ext, NONE);
        c.g_free(ext);
        return;
    }
    const t = c.gst_tag_get_type(gst_tag);
    if (t == c.G_TYPE_UINT) {
        const is_track = c.strcmp(gst_tag, c.GST_TAG_TRACK_NUMBER) == 0;
        const is_disc = c.strcmp(gst_tag, c.GST_TAG_ALBUM_VOLUME_NUMBER) == 0;
        var chk: [*c]u8 = null;
        const tmp: c.guint = @truncate(c.g_ascii_strtoull(value, &chk, 10));
        if (chk[0] == '/' and (is_track or is_disc)) {
            chk += 1;
            const count: c.guint = @truncate(c.g_ascii_strtoull(chk, &chk, 10));
            if (chk[0] != 0 or count == 0) return;
            c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, if (is_track) c.GST_TAG_TRACK_COUNT else c.GST_TAG_ALBUM_VOLUME_COUNT, count, NONE);
        }
        if (chk[0] == 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, gst_tag, tmp, NONE);
    } else if (t == c.G_TYPE_STRING) {
        var valid: [*c]u8 = null;
        if (c.strcmp(tag, "LANGUAGE") == 0) {
            const s = c.strchr(value, '[');
            if (s != null and c.strchr(s, ']') == s + 4) {
                valid = c.g_strndup(s + 1, 3);
            } else if (s != null and c.strchr(s, ']') == s + 3) valid = c.g_strndup(s + 1, 2);
        } else if (c.strcmp(tag, "LICENSE") == 0) {
            if (c.gst_uri_is_valid(value) != 0) gst_tag = c.GST_TAG_LICENSE_URI;
        }
        if (valid == null) valid = c.g_strdup(value);
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, gst_tag, valid, NONE);
        c.g_free(valid);
    } else if (t == c.G_TYPE_DOUBLE) {
        if (c.strcmp(tag, "R128_TRACK_GAIN") == 0 or c.strcmp(tag, "R128_ALBUM_GAIN") == 0) {
            var chk: [*c]u8 = null;
            const tmp: c.gint = @truncate(c.g_ascii_strtoll(value, &chk, 10));
            if (chk[0] != 0 or tmp < -32768 or tmp > 32767) return;
            c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, gst_tag, @as(f64, @floatFromInt(tmp)) / 256.0, NONE);
            return;
        }
        const dup = c.g_strdup(value);
        _ = c.g_strdelimit(dup, ",", '.');
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, gst_tag, c.g_ascii_strtod(dup, null), NONE);
        c.g_free(dup);
    } else if (t == c.gst_date_time_get_type()) {
        const dt = c.gst_date_time_new_from_iso8601_string(value);
        if (dt != null) {
            c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, gst_tag, dt, NONE);
            c.gst_date_time_unref(dt);
        }
    }
}

fn addCoverart(list: [*c]c.GstTagList, b64: [*c]u8, len: usize) void {
    if (len < 2) return;
    var out_len: usize = 0;
    _ = c.g_base64_decode_inplace(b64, &out_len);
    if (out_len == 0) return;
    const img = tags.gst_tag_image_data_to_image_sample(@ptrCast(b64), @intCast(out_len), c.GST_TAG_IMAGE_TYPE_NONE) orelse return;
    c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, c.GST_TAG_PREVIEW_IMAGE, img, NONE);
    c.gst_mini_object_unref(@ptrCast(@alignCast(img)));
}

fn addPicture(list: [*c]c.GstTagList, value: [*c]u8) void {
    var len: usize = 0;
    _ = c.g_base64_decode_inplace(value, &len);
    if (len == 0) return;
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, @ptrCast(value), @intCast(len));
    var img_type: u32 = 0;
    var mlen: u32 = 0;
    var dlen: u32 = 0;
    var ilen: u32 = 0;
    var data: [*c]const u8 = null;
    if (c.gst_byte_reader_get_uint32_be(&r, &img_type) == 0) return;
    if (c.gst_byte_reader_get_uint32_be(&r, &mlen) == 0) return;
    if (c.gst_byte_reader_skip(&r, mlen) == 0) return;
    if (c.gst_byte_reader_get_uint32_be(&r, &dlen) == 0) return;
    if (c.gst_byte_reader_skip(&r, dlen) == 0) return;
    if (c.gst_byte_reader_skip(&r, 16) == 0) return;
    if (c.gst_byte_reader_get_uint32_be(&r, &ilen) == 0) return;
    if (c.gst_byte_reader_get_data(&r, ilen, &data) == 0) return;
    _ = id3.gst_tag_list_add_id3_image(list, data, ilen, img_type);
}

fn readLe32(p: [*c]const u8) u32 {
    return @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16 | @as(u32, p[3]) << 24;
}

pub export fn gst_tag_list_from_vorbiscomment(data_in: [*c]const u8, size_in: c.gsize, id_data: [*c]const u8, id_len: c.guint, vendor: [*c][*c]u8) [*c]c.GstTagList {
    const fname = "gst_tag_list_from_vorbiscomment";
    if (!check.that(data_in != null, fname, "data != NULL")) return null;
    if (!check.that(id_data != null or id_len == 0, fname, "id_data != NULL || id_data_length == 0")) return null;
    var data = data_in;
    var size = size_in;
    var cur_size: c.guint = 0;
    var cur: [*c]const u8 = null;
    const list = c.gst_tag_list_new_empty();
    parse: {
        if (size < 11 or size <= @as(usize, id_len) + 4) break :parse;
        if (id_len > 0 and c.memcmp(data, id_data, id_len) != 0) break :parse;
        const Adv = struct {
            fn adv(d: *[*c]const u8, s: *usize, x: usize, cs: *c.guint, cu: *[*c]const u8) bool {
                d.* += x;
                s.* -%= x;
                if (s.* < 4) return false;
                cs.* = readLe32(d.*);
                d.* += 4;
                s.* -= 4;
                if (cs.* > s.*) return false;
                cu.* = d.*;
                return true;
            }
        };
        if (!Adv.adv(&data, &size, id_len, &cur_size, &cur)) break :parse;
        if (vendor != null) vendor.* = c.g_strndup(cur, cur_size);
        if (!Adv.adv(&data, &size, cur_size, &cur_size, &cur)) break :parse;
        var iterations = cur_size;
        cur_size = 0;
        while (iterations != 0) {
            if (!Adv.adv(&data, &size, cur_size, &cur_size, &cur)) break :parse;
            iterations -= 1;
            const s = c.g_strndup(cur, cur_size);
            defer c.g_free(s);
            const v = c.strchr(s, '=');
            if (v == null) continue;
            v[0] = 0;
            const value = v + 1;
            const vlen = c.strlen(value);
            if (vlen == 0 or c.g_utf8_validate(value, @intCast(vlen), null) == 0) continue;
            if (c.g_ascii_strcasecmp(s, "COVERARTMIME") == 0) continue;
            if (c.g_ascii_strcasecmp(s, "COVERART") == 0) {
                addCoverart(list, value, vlen);
            } else if (c.g_ascii_strcasecmp(s, "METADATA_BLOCK_PICTURE") == 0) {
                addPicture(list, value);
            } else if (c.g_utf8_validate(s, -1, null) != 0) gst_vorbis_tag_add(list, s, value);
        }
        return list;
    }
    if (vendor != null and vendor.* != null) {
        c.g_free(vendor.*);
        vendor.* = null;
    }
    c.gst_tag_list_unref(list);
    return null;
}

pub export fn gst_tag_list_from_vorbiscomment_buffer(buffer: [*c]c.GstBuffer, id_data: [*c]const u8, id_len: c.guint, vendor: [*c][*c]u8) [*c]c.GstTagList {
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buffer, &info, c.GST_MAP_READ) == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/tag/gstvorbistag.c", @as(c_int, 545), "gst_tag_list_from_vorbiscomment_buffer");
        return null;
    }
    defer c.gst_buffer_unmap(buffer, &info);
    return gst_tag_list_from_vorbiscomment(info.data, info.size, id_data, id_len, vendor);
}

fn metadataBlockPicture(tag: [*c]const u8, image_value: [*c]const c.GValue) ?*c.GList {
    if (!check.that(image_value != null, "gst_tag_to_metadata_block_picture", "image_value != NULL")) return null;
    const sample: ?*c.GstSample = @ptrCast(@alignCast(c.g_value_get_boxed(image_value)));
    const buffer = c.gst_sample_get_buffer(sample);
    const caps = c.gst_sample_get_caps(sample);
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, "gst_tag_to_metadata_block_picture", "gst_caps_is_fixed (caps)")) return null;
    const ms = c.gst_caps_get_structure(caps, 0);
    var mime = c.gst_structure_get_name(ms);
    if (c.strcmp(mime, "text/uri-list") == 0) mime = "-->";
    const mlen: c.guint = @intCast(c.strlen(mime));
    var image_type: c.GstTagImageType = c.GST_TAG_IMAGE_TYPE_NONE;
    var width: c.gint = 0;
    var height: c.gint = 0;
    _ = c.gst_structure_get(ms, "image-type", enums.gst_tag_image_type_get_type(), &image_type, "width", c.G_TYPE_INT, &width, "height", c.G_TYPE_INT, &height, NONE);
    if (image_type == c.GST_TAG_IMAGE_TYPE_NONE) {
        const info_s = c.gst_sample_get_info(sample);
        if (info_s != null and c.gst_structure_has_name(info_s, "GstTagImageInfo") != 0) _ = c.gst_structure_get(info_s, "image-type", enums.gst_tag_image_type_get_type(), &image_type, NONE);
    }
    const block_len: c.guint = @intCast(32 + mlen + c.gst_buffer_get_size(buffer));
    var w: c.GstByteWriter = undefined;
    c.gst_byte_writer_init_with_size(&w, block_len, 1);
    var code: u32 = 0;
    if (image_type == c.GST_TAG_IMAGE_TYPE_NONE and c.strcmp(tag, c.GST_TAG_PREVIEW_IMAGE) == 0) {
        code = 1;
    } else {
        code = if (image_type == c.GST_TAG_IMAGE_TYPE_NONE) @bitCast(@as(i32, c.GST_TAG_IMAGE_TYPE_UNDEFINED)) else @bitCast(@as(i32, image_type + 2));
    }
    _ = c.gst_byte_writer_put_uint32_be(&w, code);
    _ = c.gst_byte_writer_put_uint32_be(&w, mlen);
    _ = c.gst_byte_writer_put_data(&w, @ptrCast(mime), mlen);
    _ = c.gst_byte_writer_put_uint32_be(&w, 0);
    _ = c.gst_byte_writer_put_uint32_be(&w, @bitCast(width));
    _ = c.gst_byte_writer_put_uint32_be(&w, @bitCast(height));
    _ = c.gst_byte_writer_put_uint32_be(&w, 0);
    _ = c.gst_byte_writer_put_uint32_be(&w, 0);
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buffer, &map, c.GST_MAP_READ) == 0) {
        c.gst_byte_writer_reset(&w);
        return null;
    }
    _ = c.gst_byte_writer_put_uint32_be(&w, @intCast(map.size));
    _ = c.gst_byte_writer_put_data(&w, map.data, @intCast(map.size));
    c.gst_buffer_unmap(buffer, &map);
    const block = c.gst_byte_writer_reset_and_get_data(&w);
    const b64 = c.g_base64_encode(block, block_len);
    c.g_free(block);
    const res = c.g_strdup_printf("METADATA_BLOCK_PICTURE=%s", b64);
    c.g_free(b64);
    return c.g_list_append(null, res);
}

fn reached(comptime line: c_int) void {
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/tag/gstvorbistag.c", line, "gst_tag_to_vorbis_comments");
}

pub export fn gst_tag_to_vorbis_comments(list: [*c]const c.GstTagList, tag: [*c]const u8) ?*c.GList {
    const fname = "gst_tag_to_vorbis_comments";
    if (!check.that(list != null, fname, "list != NULL")) return null;
    if (!check.that(tag != null, fname, "tag != NULL")) return null;
    if ((c.strcmp(tag, c.GST_TAG_PREVIEW_IMAGE) == 0 and c.gst_tag_list_get_tag_size(list, c.GST_TAG_IMAGE) == 0) or c.strcmp(tag, c.GST_TAG_IMAGE) == 0) return metadataBlockPicture(tag, c.gst_tag_list_get_value_index(list, tag, 0));
    var vtag: [*c]const u8 = null;
    if (c.strcmp(tag, c.GST_TAG_EXTENDED_COMMENT) != 0) {
        vtag = gst_tag_to_vorbis_tag(tag);
        if (vtag == null) return null;
    }
    var l: ?*c.GList = null;
    var i: c.guint = 0;
    while (i < c.gst_tag_list_get_tag_size(list, tag)) : (i += 1) {
        const t = c.gst_tag_get_type(tag);
        var result: [*c]u8 = null;
        if (t == c.G_TYPE_UINT) {
            var u: c.guint = 0;
            if (c.gst_tag_list_get_uint_index(list, tag, i, &u) == 0) {
                reached(714);
                return null;
            }
            result = c.g_strdup_printf("%s=%u", vtag, u);
        } else if (t == c.G_TYPE_STRING) {
            var s: [*c]const u8 = null;
            if (c.gst_tag_list_peek_string_index(list, tag, i, &s) == 0) {
                reached(722);
                return null;
            }
            if (vtag == null) {
                var key: [*c]u8 = null;
                var val: [*c]u8 = null;
                if (tags.gst_tag_parse_extended_comment(s, &key, null, &val, 1) == 0) continue;
                result = c.g_strdup_printf("%s=%s", key, val);
                c.g_free(key);
                c.g_free(val);
            } else result = c.g_strdup_printf("%s=%s", vtag, s);
        } else if (t == c.G_TYPE_DOUBLE) {
            var value: f64 = 0;
            if (c.gst_tag_list_get_double_index(list, tag, i, &value) == 0) {
                reached(746);
                return null;
            }
            if (c.strcmp(tag, c.GST_TAG_TRACK_GAIN_R128) == 0 or c.strcmp(tag, c.GST_TAG_ALBUM_GAIN_R128) == 0) {
                result = c.g_strdup_printf("%s=%u", vtag, @as(c.gint, @intFromFloat(value * 256.0)));
            } else {
                var fb: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
                _ = c.g_ascii_formatd(&fb, fb.len, "%f", value);
                result = c.g_strconcat(vtag, "=", &fb, NONE);
            }
        } else if (t == c.gst_date_time_get_type()) {
            var dt: ?*c.GstDateTime = null;
            if (c.gst_tag_list_get_date_time_index(list, tag, i, &dt) != 0) {
                const s = c.gst_date_time_to_iso8601_string(dt);
                result = c.g_strdup_printf("%s=%s", vtag, s);
                c.g_free(s);
                c.gst_date_time_unref(dt);
            }
        } else continue;
        l = c.g_list_prepend(l, result);
    }
    return c.g_list_reverse(l);
}

const ForEach = struct {
    count: c.guint = 0,
    data_count: c.guint = 0,
    entries: ?*c.GList = null,
};

fn writeOne(list: [*c]const c.GstTagList, tag: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const d: *ForEach = @ptrCast(@alignCast(data));
    const comments = gst_tag_to_vorbis_comments(list, tag);
    var it = comments;
    while (it) |n| : (it = n.next) {
        const s: [*c]u8 = @ptrCast(n.data);
        d.count += 1;
        d.data_count += @intCast(c.strlen(s));
        d.entries = c.g_list_prepend(d.entries, s);
    }
    c.g_list_free(comments);
}

fn freeFn(p: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_free(p);
}

pub export fn gst_tag_list_to_vorbiscomment_buffer(list: [*c]const c.GstTagList, id_data: [*c]const u8, id_len: c.guint, vendor_in: [*c]const u8) [*c]c.GstBuffer {
    const fname = "gst_tag_list_to_vorbiscomment_buffer";
    const is_list = list != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(list))).type == c.gst_tag_list_get_type();
    if (!check.that(is_list, fname, "GST_IS_TAG_LIST (list)")) return null;
    if (!check.that(id_data != null or id_len == 0, fname, "id_data != NULL || id_data_length == 0")) return null;
    const vendor: [*c]const u8 = if (vendor_in == null) "GStreamer encoded vorbiscomment" else vendor_in;
    const vlen: c.guint = @intCast(c.strlen(vendor));
    var d = ForEach{};
    c.gst_tag_list_foreach(list, writeOne, &d);
    const required: usize = id_len + 4 + vlen + 4 + 1 + 4 * d.count + d.data_count;
    const buffer = c.gst_buffer_new_allocate(null, required, null);
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &info, c.GST_MAP_WRITE);
    var p = info.data;
    if (id_len > 0) {
        @memcpy(p[0..id_len], id_data[0..id_len]);
        p += id_len;
    }
    std.mem.writeInt(u32, p[0..4], vlen, .little);
    p += 4;
    @memcpy(p[0..vlen], vendor[0..vlen]);
    p += vlen;
    d.entries = c.g_list_reverse(d.entries);
    std.mem.writeInt(u32, p[0..4], d.count, .little);
    p += 4;
    var l = d.entries;
    while (l) |n| : (l = n.next) {
        const s: [*c]const u8 = @ptrCast(n.data);
        const n_len: u32 = @intCast(c.strlen(s));
        std.mem.writeInt(u32, p[0..4], n_len, .little);
        p += 4;
        @memcpy(p[0..n_len], s[0..n_len]);
        p += n_len;
    }
    c.g_list_foreach(d.entries, freeFn, null);
    c.g_list_free(d.entries);
    p[0] = 1;
    c.gst_buffer_unmap(buffer, &info);
    return buffer;
}
