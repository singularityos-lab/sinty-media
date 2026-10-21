const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const enums = @import("enumtypes.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const TEXT_DOMAIN = "gst-plugins-base-1.0";

pub fn tr(s: [*:0]const u8) [*c]const u8 {
    return c.g_dgettext(TEXT_DOMAIN, s);
}

var mb_once = std.mem.zeroes(c.GOnce);

const Reg = struct { name: [*:0]const u8, t: *const fn () c.GType, nick: [*:0]const u8, blurb: [*:0]const u8, first: bool, translate: bool = true };

fn tString() c.GType {
    return c.G_TYPE_STRING;
}

fn tDouble() c.GType {
    return c.G_TYPE_DOUBLE;
}

fn tInt() c.GType {
    return c.G_TYPE_INT;
}

fn tBool() c.GType {
    return c.G_TYPE_BOOLEAN;
}

fn tFraction() c.GType {
    return c.gst_fraction_get_type();
}

fn tSample() c.GType {
    return c._gst_sample_type;
}

const REGS = [_]Reg{
    .{ .name = c.GST_TAG_MUSICBRAINZ_TRACKID, .t = tString, .nick = "track ID", .blurb = "MusicBrainz track ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_ARTISTID, .t = tString, .nick = "artist ID", .blurb = "MusicBrainz artist ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_ALBUMID, .t = tString, .nick = "album ID", .blurb = "MusicBrainz album ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_ALBUMARTISTID, .t = tString, .nick = "album artist ID", .blurb = "MusicBrainz album artist ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_RELEASEGROUPID, .t = tString, .nick = "release group ID", .blurb = "MusicBrainz release group ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_RELEASETRACKID, .t = tString, .nick = "release track ID", .blurb = "MusicBrainz release track ID", .first = false },
    .{ .name = c.GST_TAG_MUSICBRAINZ_TRMID, .t = tString, .nick = "track TRM ID", .blurb = "MusicBrainz TRM ID", .first = false },
    .{ .name = c.GST_TAG_ACOUSTID_ID, .t = tString, .nick = "AcoustID ID", .blurb = "AcoustID ID", .first = false },
    .{ .name = c.GST_TAG_ACOUSTID_FINGERPRINT, .t = tString, .nick = "AcoustID fingerprint (chromaprint)", .blurb = "AcoustID fingerprint (chromaprint)", .first = false },
    .{ .name = c.GST_TAG_CDDA_CDDB_DISCID, .t = tString, .nick = "discid", .blurb = "CDDB discid for metadata retrieval", .first = true, .translate = false },
    .{ .name = c.GST_TAG_CDDA_CDDB_DISCID_FULL, .t = tString, .nick = "discid full", .blurb = "CDDB discid for metadata retrieval (full)", .first = true, .translate = false },
    .{ .name = c.GST_TAG_CDDA_MUSICBRAINZ_DISCID, .t = tString, .nick = "musicbrainz-discid", .blurb = "Musicbrainz discid for metadata retrieval", .first = true, .translate = false },
    .{ .name = c.GST_TAG_CDDA_MUSICBRAINZ_DISCID_FULL, .t = tString, .nick = "musicbrainz-discid-full", .blurb = "Musicbrainz discid for metadata retrieval (full)", .first = true, .translate = false },
    .{ .name = c.GST_TAG_CAPTURING_SHUTTER_SPEED, .t = tFraction, .nick = "capturing shutter speed", .blurb = "Shutter speed used when capturing an image, in seconds", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_FOCAL_RATIO, .t = tDouble, .nick = "capturing focal ratio", .blurb = "Focal ratio (f-number) used when capturing the image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_FOCAL_LENGTH, .t = tDouble, .nick = "capturing focal length", .blurb = "Focal length of the lens used capturing the image, in mm", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_FOCAL_LENGTH_35_MM, .t = tDouble, .nick = "capturing 35 mm equivalent focal length", .blurb = "35 mm equivalent focal length of the lens used capturing the image, in mm", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_DIGITAL_ZOOM_RATIO, .t = tDouble, .nick = "capturing digital zoom ratio", .blurb = "Digital zoom ratio used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_ISO_SPEED, .t = tInt, .nick = "capturing iso speed", .blurb = "The ISO speed used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_EXPOSURE_PROGRAM, .t = tString, .nick = "capturing exposure program", .blurb = "The exposure program used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_EXPOSURE_MODE, .t = tString, .nick = "capturing exposure mode", .blurb = "The exposure mode used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_EXPOSURE_COMPENSATION, .t = tDouble, .nick = "capturing exposure compensation", .blurb = "The exposure compensation used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_SCENE_CAPTURE_TYPE, .t = tString, .nick = "capturing scene capture type", .blurb = "The scene capture mode used when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_GAIN_ADJUSTMENT, .t = tString, .nick = "capturing gain adjustment", .blurb = "The overall gain adjustment applied on an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_WHITE_BALANCE, .t = tString, .nick = "capturing white balance", .blurb = "The white balance mode set when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_LIGHT_SOURCE, .t = tString, .nick = "capturing light source", .blurb = "The light source indicates the kind of light when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_CONTRAST, .t = tString, .nick = "capturing contrast", .blurb = "The direction of contrast processing applied when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_SATURATION, .t = tString, .nick = "capturing saturation", .blurb = "The direction of saturation processing applied when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_SHARPNESS, .t = tString, .nick = "capturing sharpness", .blurb = "The direction of sharpness processing applied when capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_FLASH_FIRED, .t = tBool, .nick = "capturing flash fired", .blurb = "If the flash fired while capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_FLASH_MODE, .t = tString, .nick = "capturing flash mode", .blurb = "The selected flash mode while capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_METERING_MODE, .t = tString, .nick = "capturing metering mode", .blurb = "The metering mode used while determining exposure for capturing an image", .first = false },
    .{ .name = c.GST_TAG_CAPTURING_SOURCE, .t = tString, .nick = "capturing source", .blurb = "The source or type of device used for the capture", .first = false },
    .{ .name = c.GST_TAG_IMAGE_HORIZONTAL_PPI, .t = tDouble, .nick = "image horizontal ppi", .blurb = "Media (image/video) intended horizontal pixel density in ppi", .first = false },
    .{ .name = c.GST_TAG_IMAGE_VERTICAL_PPI, .t = tDouble, .nick = "image vertical ppi", .blurb = "Media (image/video) intended vertical pixel density in ppi", .first = false },
    .{ .name = "private-id3v2-frame", .t = tSample, .nick = "ID3v2 frame", .blurb = "unparsed id3v2 tag frame", .first = true },
    .{ .name = c.GST_TAG_MUSICAL_KEY, .t = tString, .nick = "musical-key", .blurb = "Initial key in which the sound starts", .first = true },
};

fn registerAll(_: c.gpointer) callconv(.c) c.gpointer {
    for (REGS) |r| {
        const nick = if (r.translate) tr(r.nick) else r.nick;
        const blurb = if (r.translate) tr(r.blurb) else r.blurb;
        c.gst_tag_register_static(r.name, c.GST_TAG_FLAG_META, r.t(), nick, blurb, if (r.first) c.gst_tag_merge_use_first else null);
    }
    return null;
}

pub export fn gst_tag_register_musicbrainz_tags() void {
    _ = c.g_once_impl(&mb_once, registerAll, null);
}

fn imageTypeValid(t: c.GstTagImageType) bool {
    const k = c.g_type_class_ref(enums.gst_tag_image_type_get_type());
    defer c.g_type_class_unref(k);
    return c.g_enum_get_value(@ptrCast(@alignCast(k)), t) != null;
}

pub export fn gst_tag_parse_extended_comment(ext: [*c]const u8, key: [*c][*c]u8, lang: [*c][*c]u8, value: [*c][*c]u8, fail_if_no_key: c.gboolean) c.gboolean {
    const fname = "gst_tag_parse_extended_comment";
    if (!check.that(ext != null, fname, "ext_comment != NULL")) return 0;
    if (!check.that(c.g_utf8_validate(ext, -1, null) != 0, fname, "g_utf8_validate (ext_comment, -1, NULL)")) return 0;
    if (key != null) key.* = null;
    if (lang != null) lang.* = null;
    const div = c.strchr(ext, '=');
    const bop = c.strchr(ext, '[');
    const bcl = c.strchr(ext, ']');
    if (div == null) {
        if (fail_if_no_key != 0) return 0;
        if (value != null) value.* = c.g_strdup(ext);
        return 1;
    }
    const base = @intFromPtr(ext);
    if (bop != null and @intFromPtr(bop) < @intFromPtr(div)) {
        if (@intFromPtr(bcl) < @intFromPtr(bop) or @intFromPtr(bcl) > @intFromPtr(div)) return 0;
        if (key != null) key.* = c.g_strndup(ext, @intFromPtr(bop) - base);
        if (lang != null) lang.* = c.g_strndup(bop + 1, @intFromPtr(bcl) - @intFromPtr(bop) - 1);
    } else if (key != null) key.* = c.g_strndup(ext, @intFromPtr(div) - base);
    if (value != null) value.* = c.g_strdup(div + 1);
    return 1;
}

fn finish(utf8: [*c]u8) [*c]u8 {
    _ = c.g_strchomp(utf8);
    if (utf8 != null and utf8[0] != 0) return utf8;
    c.g_free(utf8);
    return null;
}

fn convertExact(data: [*c]const u8, size: usize, from: [*c]const u8) [*c]u8 {
    var read: usize = 0;
    const r = c.g_convert(data, @intCast(size), "UTF-8", from, &read, null, null);
    if (r == null) return null;
    if (read == size) return r;
    c.g_free(r);
    return null;
}

pub export fn gst_tag_freeform_string_to_utf8(data: [*c]const u8, size_in: c.gint, env_vars: [*c][*c]const u8) [*c]u8 {
    if (!check.that(data != null, "gst_tag_freeform_string_to_utf8", "data != NULL")) return null;
    var size: usize = if (size_in < 0) c.strlen(data) else @intCast(size_in);
    while (size > 0 and data[size - 1] == 0) size -= 1;
    if (c.g_utf8_validate(data, @intCast(size), null) != 0) return finish(c.g_strndup(data, size));
    if (size >= 2) {
        var cs: [*c]const u8 = null;
        var prefix: usize = 0;
        var ssize: usize = 0;
        if (size >= 4) {
            prefix = 4;
            ssize = (size - 4) & ~@as(usize, 3);
            const v = @as(u32, data[0]) << 24 | @as(u32, data[1]) << 16 | @as(u32, data[2]) << 8 | data[3];
            if (v == 0x0000FEFF) cs = "UTF-32BE" else if (v == 0xFFFE0000) cs = "UTF-32LE";
        }
        if (cs == null) {
            prefix = 2;
            ssize = (size - 2) & ~@as(usize, 1);
            const v = @as(u16, data[0]) << 8 | data[1];
            if (v == 0xFEFF) cs = "UTF-16BE" else if (v == 0xFFFE) cs = "UTF-16LE";
        }
        if (cs != null) {
            const r = convertExact(data + prefix, ssize, cs);
            if (r != null) return finish(r);
        }
    }
    var ev = env_vars;
    while (ev != null and ev[0] != null) : (ev += 1) {
        const env = c.g_getenv(ev[0]);
        if (env == null or env[0] == 0) continue;
        const sets = c.g_strsplit(env, ":", -1);
        var s = sets;
        while (s != null and s[0] != null) : (s += 1) {
            const r = convertExact(data, size, s[0]);
            if (r != null) {
                c.g_strfreev(sets);
                return finish(r);
            }
        }
        c.g_strfreev(sets);
    }
    var cur: [*c]const u8 = null;
    if (c.g_get_charset(&cur) == 0) {
        var read: usize = 0;
        const r = c.g_locale_to_utf8(data, @intCast(size), &read, null, null);
        if (r != null) {
            if (read == size) return finish(r);
            c.g_free(r);
        }
    }
    var err: [*c]c.GError = null;
    var read: usize = 0;
    var utf8 = c.g_convert(data, @intCast(size), "UTF-8", "WINDOWS-1252", &read, null, &err);
    if (err != null) {
        if (err[0].code == c.G_CONVERT_ERROR_NO_CONVERSION) {
            c.g_free(utf8);
            utf8 = c.g_convert(data, @intCast(size), "UTF-8", "ISO-8859-1", &read, null, null);
        }
        c.g_error_free(err);
    }
    if (utf8 != null and read == size) return finish(utf8);
    c.g_free(utf8);
    return null;
}

pub export fn gst_tag_image_data_to_image_sample(image_data: [*c]const u8, len: c.guint, image_type: c.GstTagImageType) ?*c.GstSample {
    const fname = "gst_tag_image_data_to_image_sample";
    if (!check.that(image_data != null, fname, "image_data != NULL")) return null;
    if (!check.that(len > 0 or len == std.math.maxInt(u32), fname, "image_data_len > 0 || image_data_len == G_MAXUINT32")) return null;
    if (!check.that(imageTypeValid(image_type), fname, "gst_tag_image_type_is_valid (image_type)")) return null;
    const image = c.gst_buffer_new_allocate(null, len +% 1, null);
    if (image == null) return null;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(image, &info, c.GST_MAP_WRITE);
    @memcpy(info.data[0..len], image_data[0..len]);
    info.data[len] = 0;
    c.gst_buffer_unmap(image, &info);
    const caps = c.gst_type_find_helper_for_buffer(null, image, null);
    if (caps == null) {
        c.gst_buffer_unref(image);
        return null;
    }
    const name = c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0));
    const uri = c.g_str_equal(name, "text/uri-list") != 0;
    if (c.g_str_has_prefix(name, "image/") == 0 and c.g_str_has_prefix(name, "video/") == 0 and !uri) {
        c.gst_buffer_unref(image);
        c.gst_caps_unref(caps);
        return null;
    }
    if (!uri) c.gst_buffer_set_size(image, len);
    var info_s: ?*c.GstStructure = null;
    if (image_type != c.GST_TAG_IMAGE_TYPE_NONE) info_s = c.gst_structure_new("GstTagImageInfo", "image-type", enums.gst_tag_image_type_get_type(), image_type, @as(?*anyopaque, null));
    const sample = c.gst_sample_new(image, caps, null, info_s);
    c.gst_buffer_unref(image);
    c.gst_caps_unref(caps);
    return sample;
}
