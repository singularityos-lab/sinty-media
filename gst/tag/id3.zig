const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tables = @import("tables.zig");
const tags = @import("tags.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const Match = struct { gst: [*:0]const u8, orig: [*:0]const u8 };

const TAG_MATCHES = [_]Match{
    .{ .gst = c.GST_TAG_TITLE, .orig = "TIT2" },
    .{ .gst = c.GST_TAG_ALBUM, .orig = "TALB" },
    .{ .gst = c.GST_TAG_TRACK_NUMBER, .orig = "TRCK" },
    .{ .gst = c.GST_TAG_ARTIST, .orig = "TPE1" },
    .{ .gst = c.GST_TAG_ALBUM_ARTIST, .orig = "TPE2" },
    .{ .gst = c.GST_TAG_COMPOSER, .orig = "TCOM" },
    .{ .gst = c.GST_TAG_CONDUCTOR, .orig = "TPE3" },
    .{ .gst = c.GST_TAG_COPYRIGHT, .orig = "TCOP" },
    .{ .gst = c.GST_TAG_COPYRIGHT_URI, .orig = "WCOP" },
    .{ .gst = c.GST_TAG_ENCODED_BY, .orig = "TENC" },
    .{ .gst = c.GST_TAG_GENRE, .orig = "TCON" },
    .{ .gst = c.GST_TAG_DATE_TIME, .orig = "TDRC" },
    .{ .gst = c.GST_TAG_COMMENT, .orig = "COMM" },
    .{ .gst = c.GST_TAG_ALBUM_VOLUME_NUMBER, .orig = "TPOS" },
    .{ .gst = c.GST_TAG_DURATION, .orig = "TLEN" },
    .{ .gst = c.GST_TAG_ISRC, .orig = "TSRC" },
    .{ .gst = c.GST_TAG_IMAGE, .orig = "APIC" },
    .{ .gst = c.GST_TAG_ENCODER, .orig = "TSSE" },
    .{ .gst = c.GST_TAG_BEATS_PER_MINUTE, .orig = "TBPM" },
    .{ .gst = c.GST_TAG_ARTIST_SORTNAME, .orig = "TSOP" },
    .{ .gst = c.GST_TAG_ALBUM_SORTNAME, .orig = "TSOA" },
    .{ .gst = c.GST_TAG_TITLE_SORTNAME, .orig = "TSOT" },
    .{ .gst = c.GST_TAG_PUBLISHER, .orig = "TPUB" },
    .{ .gst = c.GST_TAG_INTERPRETED_BY, .orig = "TPE4" },
    .{ .gst = c.GST_TAG_MUSICAL_KEY, .orig = "TKEY" },
    .{ .gst = c.GST_TAG_PRIVATE_DATA, .orig = "PRIV" },
};

const USER_MATCHES = [_]Match{
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASETRACKID, .orig = "TXXX|musicbrainz_trackid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ARTISTID, .orig = "TXXX|musicbrainz_artistid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMID, .orig = "TXXX|musicbrainz_albumid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMARTISTID, .orig = "TXXX|musicbrainz_albumartistid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASEGROUPID, .orig = "TXXX|musicbrainz_releasegroupid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_TRMID, .orig = "TXXX|musicbrainz_trmid" },
    .{ .gst = c.GST_TAG_CDDA_MUSICBRAINZ_DISCID, .orig = "TXXX|musicbrainz_discid" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASETRACKID, .orig = "TXXX|MusicBrainz Release Track Id" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ARTISTID, .orig = "TXXX|MusicBrainz Artist Id" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMID, .orig = "TXXX|MusicBrainz Album Id" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_ALBUMARTISTID, .orig = "TXXX|MusicBrainz Album Artist Id" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_RELEASEGROUPID, .orig = "TXXX|MusicBrainz Release Group Id" },
    .{ .gst = c.GST_TAG_MUSICBRAINZ_TRMID, .orig = "TXXX|MusicBrainz TRM Id" },
    .{ .gst = c.GST_TAG_ACOUSTID_ID, .orig = "TXXX|Acoustid Id" },
    .{ .gst = c.GST_TAG_ACOUSTID_FINGERPRINT, .orig = "TXXX|Acoustid Fingerprint" },
    .{ .gst = c.GST_TAG_CDDA_MUSICBRAINZ_DISCID, .orig = "TXXX|MusicBrainz DiscID" },
    .{ .gst = c.GST_TAG_TRACK_GAIN, .orig = "TXXX|replaygain_track_gain" },
    .{ .gst = c.GST_TAG_TRACK_PEAK, .orig = "TXXX|replaygain_track_peak" },
    .{ .gst = c.GST_TAG_ALBUM_GAIN, .orig = "TXXX|replaygain_album_gain" },
    .{ .gst = c.GST_TAG_ALBUM_PEAK, .orig = "TXXX|replaygain_album_peak" },
    .{ .gst = c.GST_TAG_CDDA_CDDB_DISCID, .orig = "TXXX|discid" },
    .{ .gst = c.GST_TAG_CDDA_CDDB_DISCID, .orig = "TXXX|CDDB DiscID" },
};

pub export fn gst_tag_from_id3_tag(id3: [*c]const u8) [*c]const u8 {
    if (!check.that(id3 != null, "gst_tag_from_id3_tag", "id3_tag != NULL")) return null;
    for (TAG_MATCHES) |m| {
        if (c.strncmp(id3, m.orig, 5) == 0) return m.gst;
    }
    return null;
}

pub export fn gst_tag_from_id3_user_tag(t: [*c]const u8, user: [*c]const u8) [*c]const u8 {
    const fname = "gst_tag_from_id3_user_tag";
    if (!check.that(t != null and c.strlen(t) == 4, fname, "type != NULL && strlen (type) == 4")) return null;
    if (!check.that(user != null, fname, "id3_user_tag != NULL")) return null;
    for (USER_MATCHES) |m| {
        if (c.strncmp(t, m.orig, 4) == 0 and c.g_ascii_strcasecmp(user, m.orig + 5) == 0) return m.gst;
    }
    return null;
}

pub export fn gst_tag_to_id3_tag(tag: [*c]const u8) [*c]const u8 {
    if (!check.that(tag != null, "gst_tag_to_id3_tag", "gst_tag != NULL")) return null;
    for (TAG_MATCHES) |m| {
        if (c.strcmp(tag, m.gst) == 0) return m.orig;
    }
    return null;
}

var v1_env = [_][*c]const u8{ "GST_ID3V1_TAG_ENCODING", "GST_ID3_TAG_ENCODING", "GST_TAG_ENCODING", null };

fn v1String(list: [*c]c.GstTagList, tag: [*c]const u8, start: [*c]const u8, size: c.gint) void {
    const utf8 = tags.gst_tag_freeform_string_to_utf8(start, size, &v1_env);
    if (utf8 != null and utf8[0] != 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, tag, utf8, @as(?*anyopaque, null));
    c.g_free(utf8);
}

pub export fn gst_tag_list_new_from_id3v1(data: [*c]const u8) [*c]c.GstTagList {
    if (!check.that(data != null, "gst_tag_list_new_from_id3v1", "data != NULL")) return null;
    if (data[0] != 'T' or data[1] != 'A' or data[2] != 'G') return null;
    const list = c.gst_tag_list_new_empty();
    const d: [*c]const u8 = @ptrCast(data);
    v1String(list, c.GST_TAG_TITLE, d + 3, 30);
    v1String(list, c.GST_TAG_ARTIST, d + 33, 30);
    v1String(list, c.GST_TAG_ALBUM, d + 63, 30);
    const ystr = c.g_strndup(d + 93, 4);
    const year = c.g_ascii_strtoll(ystr, null, 10);
    c.g_free(ystr);
    if (year > 0 and year <= 9999) {
        const dt = c.gst_date_time_new_y(@intCast(year));
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_DATE_TIME, dt, @as(?*anyopaque, null));
        c.gst_date_time_unref(dt);
    }
    if (data[125] == 0 and data[126] != 0) {
        v1String(list, c.GST_TAG_COMMENT, d + 97, 28);
        c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_TRACK_NUMBER, @as(c.guint, data[126]), @as(?*anyopaque, null));
    } else v1String(list, c.GST_TAG_COMMENT, d + 97, 30);
    if (data[127] < gst_tag_id3_genre_count() and c.gst_tag_list_is_empty(list) == 0) c.gst_tag_list_add(list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_GENRE, gst_tag_id3_genre_get(data[127]), @as(?*anyopaque, null));
    return list;
}

pub export fn gst_tag_id3_genre_count() c.guint {
    return tables.GENRES.len;
}

pub export fn gst_tag_id3_genre_get(id: c.guint) [*c]const u8 {
    if (id >= tables.GENRES.len) return null;
    return tables.GENRES[id];
}

pub export fn gst_tag_list_add_id3_image(list: [*c]c.GstTagList, image_data: [*c]const u8, len: c.guint, pic_type: c.guint) c.gboolean {
    const fname = "gst_tag_list_add_id3_image";
    const is_list = list != null and @as(*c.GstMiniObject, @ptrCast(@alignCast(list))).type == c.gst_tag_list_get_type();
    if (!check.that(is_list, fname, "GST_IS_TAG_LIST (tag_list)")) return 0;
    if (!check.that(image_data != null, fname, "image_data != NULL")) return 0;
    if (!check.that(len > 0, fname, "image_data_len > 0")) return 0;
    var name: [*c]const u8 = c.GST_TAG_IMAGE;
    var image_type: c.GstTagImageType = c.GST_TAG_IMAGE_TYPE_UNDEFINED;
    if (pic_type == 1 or pic_type == 2) {
        name = c.GST_TAG_PREVIEW_IMAGE;
        image_type = c.GST_TAG_IMAGE_TYPE_NONE;
    } else if (pic_type >= 3 and pic_type <= 0x14) image_type = @intCast(pic_type - 2);
    const image = tags.gst_tag_image_data_to_image_sample(image_data, len, image_type) orelse return 0;
    c.gst_tag_list_add(list, c.GST_TAG_MERGE_APPEND, name, image, @as(?*anyopaque, null));
    c.gst_mini_object_unref(@ptrCast(@alignCast(image)));
    return 1;
}
