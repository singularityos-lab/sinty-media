const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

var gst_tag_demux_result_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_TAG_DEMUX_RESULT_BROKEN_TAG", .value_nick = "broken-tag" },
    .{ .value = 1, .value_name = "GST_TAG_DEMUX_RESULT_AGAIN", .value_nick = "again" },
    .{ .value = 2, .value_name = "GST_TAG_DEMUX_RESULT_OK", .value_nick = "ok" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_demux_result_once: gtype.Once = .{};
fn gst_tag_demux_result_register() c.GType {
    return c.g_enum_register_static("GstTagDemuxResult", &gst_tag_demux_result_values);
}
pub export fn gst_tag_demux_result_get_type() c.GType {
    return gst_tag_demux_result_once.get(gst_tag_demux_result_register);
}

var gst_tag_image_type_values = [_]c.GEnumValue{
    .{ .value = -1, .value_name = "GST_TAG_IMAGE_TYPE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = "GST_TAG_IMAGE_TYPE_UNDEFINED", .value_nick = "undefined" },
    .{ .value = 1, .value_name = "GST_TAG_IMAGE_TYPE_FRONT_COVER", .value_nick = "front-cover" },
    .{ .value = 2, .value_name = "GST_TAG_IMAGE_TYPE_BACK_COVER", .value_nick = "back-cover" },
    .{ .value = 3, .value_name = "GST_TAG_IMAGE_TYPE_LEAFLET_PAGE", .value_nick = "leaflet-page" },
    .{ .value = 4, .value_name = "GST_TAG_IMAGE_TYPE_MEDIUM", .value_nick = "medium" },
    .{ .value = 5, .value_name = "GST_TAG_IMAGE_TYPE_LEAD_ARTIST", .value_nick = "lead-artist" },
    .{ .value = 6, .value_name = "GST_TAG_IMAGE_TYPE_ARTIST", .value_nick = "artist" },
    .{ .value = 7, .value_name = "GST_TAG_IMAGE_TYPE_CONDUCTOR", .value_nick = "conductor" },
    .{ .value = 8, .value_name = "GST_TAG_IMAGE_TYPE_BAND_ORCHESTRA", .value_nick = "band-orchestra" },
    .{ .value = 9, .value_name = "GST_TAG_IMAGE_TYPE_COMPOSER", .value_nick = "composer" },
    .{ .value = 10, .value_name = "GST_TAG_IMAGE_TYPE_LYRICIST", .value_nick = "lyricist" },
    .{ .value = 11, .value_name = "GST_TAG_IMAGE_TYPE_RECORDING_LOCATION", .value_nick = "recording-location" },
    .{ .value = 12, .value_name = "GST_TAG_IMAGE_TYPE_DURING_RECORDING", .value_nick = "during-recording" },
    .{ .value = 13, .value_name = "GST_TAG_IMAGE_TYPE_DURING_PERFORMANCE", .value_nick = "during-performance" },
    .{ .value = 14, .value_name = "GST_TAG_IMAGE_TYPE_VIDEO_CAPTURE", .value_nick = "video-capture" },
    .{ .value = 15, .value_name = "GST_TAG_IMAGE_TYPE_FISH", .value_nick = "fish" },
    .{ .value = 16, .value_name = "GST_TAG_IMAGE_TYPE_ILLUSTRATION", .value_nick = "illustration" },
    .{ .value = 17, .value_name = "GST_TAG_IMAGE_TYPE_BAND_ARTIST_LOGO", .value_nick = "band-artist-logo" },
    .{ .value = 18, .value_name = "GST_TAG_IMAGE_TYPE_PUBLISHER_STUDIO_LOGO", .value_nick = "publisher-studio-logo" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_image_type_once: gtype.Once = .{};
fn gst_tag_image_type_register() c.GType {
    return c.g_enum_register_static("GstTagImageType", &gst_tag_image_type_values);
}
pub export fn gst_tag_image_type_get_type() c.GType {
    return gst_tag_image_type_once.get(gst_tag_image_type_register);
}

var gst_tag_license_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_TAG_LICENSE_PERMITS_REPRODUCTION", .value_nick = "permits-reproduction" },
    .{ .value = 2, .value_name = "GST_TAG_LICENSE_PERMITS_DISTRIBUTION", .value_nick = "permits-distribution" },
    .{ .value = 4, .value_name = "GST_TAG_LICENSE_PERMITS_DERIVATIVE_WORKS", .value_nick = "permits-derivative-works" },
    .{ .value = 8, .value_name = "GST_TAG_LICENSE_PERMITS_SHARING", .value_nick = "permits-sharing" },
    .{ .value = 256, .value_name = "GST_TAG_LICENSE_REQUIRES_NOTICE", .value_nick = "requires-notice" },
    .{ .value = 512, .value_name = "GST_TAG_LICENSE_REQUIRES_ATTRIBUTION", .value_nick = "requires-attribution" },
    .{ .value = 1024, .value_name = "GST_TAG_LICENSE_REQUIRES_SHARE_ALIKE", .value_nick = "requires-share-alike" },
    .{ .value = 2048, .value_name = "GST_TAG_LICENSE_REQUIRES_SOURCE_CODE", .value_nick = "requires-source-code" },
    .{ .value = 4096, .value_name = "GST_TAG_LICENSE_REQUIRES_COPYLEFT", .value_nick = "requires-copyleft" },
    .{ .value = 8192, .value_name = "GST_TAG_LICENSE_REQUIRES_LESSER_COPYLEFT", .value_nick = "requires-lesser-copyleft" },
    .{ .value = 65536, .value_name = "GST_TAG_LICENSE_PROHIBITS_COMMERCIAL_USE", .value_nick = "prohibits-commercial-use" },
    .{ .value = 131072, .value_name = "GST_TAG_LICENSE_PROHIBITS_HIGH_INCOME_NATION_USE", .value_nick = "prohibits-high-income-nation-use" },
    .{ .value = 16777216, .value_name = "GST_TAG_LICENSE_CREATIVE_COMMONS_LICENSE", .value_nick = "creative-commons-license" },
    .{ .value = 33554432, .value_name = "GST_TAG_LICENSE_FREE_SOFTWARE_FOUNDATION_LICENSE", .value_nick = "free-software-foundation-license" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_tag_license_flags_once: gtype.Once = .{};
fn gst_tag_license_flags_register() c.GType {
    return c.g_flags_register_static("GstTagLicenseFlags", &gst_tag_license_flags_values);
}
pub export fn gst_tag_license_flags_get_type() c.GType {
    return gst_tag_license_flags_once.get(gst_tag_license_flags_register);
}
