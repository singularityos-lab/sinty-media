const c = @import("c.zig").c;

pub const Merge = enum { none, first, comma };

pub const Def = struct { name: [:0]const u8, flag: c.GstTagFlag, t: *const fn () c.GType, nick: [:0]const u8, blurb: [:0]const u8, merge: Merge };

fn t0() c.GType {
    return c.G_TYPE_STRING;
}

fn t1() c.GType {
    return c.g_date_get_type();
}

fn t2() c.GType {
    return c.gst_date_time_get_type();
}

fn t3() c.GType {
    return c.G_TYPE_UINT;
}

fn t4() c.GType {
    return c.G_TYPE_UINT64;
}

fn t5() c.GType {
    return c.G_TYPE_DOUBLE;
}

fn t6() c.GType {
    return c.gst_sample_get_type();
}

pub const defs = [_]Def{
    .{ .name = "title", .flag = 1, .t = t0, .nick = "title", .blurb = "commonly used title", .merge = .comma },
    .{ .name = "title-sortname", .flag = 1, .t = t0, .nick = "title sortname", .blurb = "commonly used title for sorting purposes", .merge = .none },
    .{ .name = "artist", .flag = 1, .t = t0, .nick = "artist", .blurb = "person(s) responsible for the recording", .merge = .comma },
    .{ .name = "artist-sortname", .flag = 1, .t = t0, .nick = "artist sortname", .blurb = "person(s) responsible for the recording for sorting purposes", .merge = .none },
    .{ .name = "album", .flag = 1, .t = t0, .nick = "album", .blurb = "album containing this data", .merge = .comma },
    .{ .name = "album-sortname", .flag = 1, .t = t0, .nick = "album sortname", .blurb = "album containing this data for sorting purposes", .merge = .none },
    .{ .name = "album-artist", .flag = 1, .t = t0, .nick = "album artist", .blurb = "The artist of the entire album, as it should be displayed", .merge = .comma },
    .{ .name = "album-artist-sortname", .flag = 1, .t = t0, .nick = "album artist sortname", .blurb = "The artist of the entire album, as it should be sorted", .merge = .none },
    .{ .name = "composer", .flag = 1, .t = t0, .nick = "composer", .blurb = "person(s) who composed the recording", .merge = .comma },
    .{ .name = "conductor", .flag = 1, .t = t0, .nick = "conductor", .blurb = "conductor/performer refinement", .merge = .comma },
    .{ .name = "date", .flag = 1, .t = t1, .nick = "date", .blurb = "date the data was created (as a GDate structure)", .merge = .none },
    .{ .name = "datetime", .flag = 1, .t = t2, .nick = "datetime", .blurb = "date and time the data was created (as a GstDateTime structure)", .merge = .none },
    .{ .name = "genre", .flag = 1, .t = t0, .nick = "genre", .blurb = "genre this data belongs to", .merge = .comma },
    .{ .name = "comment", .flag = 1, .t = t0, .nick = "comment", .blurb = "free text commenting the data", .merge = .first },
    .{ .name = "extended-comment", .flag = 1, .t = t0, .nick = "extended comment", .blurb = "free text commenting the data in key=value or key[en]=comment form", .merge = .first },
    .{ .name = "track-number", .flag = 1, .t = t3, .nick = "track number", .blurb = "track number inside a collection", .merge = .first },
    .{ .name = "track-count", .flag = 1, .t = t3, .nick = "track count", .blurb = "count of tracks inside collection this track belongs to", .merge = .first },
    .{ .name = "album-disc-number", .flag = 1, .t = t3, .nick = "disc number", .blurb = "disc number inside a collection", .merge = .first },
    .{ .name = "album-disc-count", .flag = 1, .t = t3, .nick = "disc count", .blurb = "count of discs inside collection this disc belongs to", .merge = .first },
    .{ .name = "location", .flag = 1, .t = t0, .nick = "location", .blurb = "Origin of media as a URI (location, where the original of the file or stream is hosted)", .merge = .comma },
    .{ .name = "homepage", .flag = 1, .t = t0, .nick = "homepage", .blurb = "Homepage for this media (i.e. artist or movie homepage)", .merge = .comma },
    .{ .name = "description", .flag = 1, .t = t0, .nick = "description", .blurb = "short text describing the content of the data", .merge = .comma },
    .{ .name = "version", .flag = 1, .t = t0, .nick = "version", .blurb = "version of this data", .merge = .none },
    .{ .name = "isrc", .flag = 1, .t = t0, .nick = "ISRC", .blurb = "International Standard Recording Code - see http://www.ifpi.org/isrc/", .merge = .none },
    .{ .name = "organization", .flag = 1, .t = t0, .nick = "organization", .blurb = "organization", .merge = .comma },
    .{ .name = "copyright", .flag = 1, .t = t0, .nick = "copyright", .blurb = "copyright notice of the data", .merge = .none },
    .{ .name = "copyright-uri", .flag = 1, .t = t0, .nick = "copyright uri", .blurb = "URI to the copyright notice of the data", .merge = .none },
    .{ .name = "encoded-by", .flag = 1, .t = t0, .nick = "encoded by", .blurb = "name of the encoding person or organization", .merge = .comma },
    .{ .name = "contact", .flag = 1, .t = t0, .nick = "contact", .blurb = "contact information", .merge = .comma },
    .{ .name = "license", .flag = 1, .t = t0, .nick = "license", .blurb = "license of data", .merge = .none },
    .{ .name = "license-uri", .flag = 1, .t = t0, .nick = "license uri", .blurb = "URI to the license of the data", .merge = .none },
    .{ .name = "performer", .flag = 1, .t = t0, .nick = "performer", .blurb = "person(s) performing", .merge = .comma },
    .{ .name = "duration", .flag = 3, .t = t4, .nick = "duration", .blurb = "length in GStreamer time units (nanoseconds)", .merge = .none },
    .{ .name = "codec", .flag = 2, .t = t0, .nick = "codec", .blurb = "codec the data is stored in", .merge = .comma },
    .{ .name = "video-codec", .flag = 2, .t = t0, .nick = "video codec", .blurb = "codec the video data is stored in", .merge = .none },
    .{ .name = "audio-codec", .flag = 2, .t = t0, .nick = "audio codec", .blurb = "codec the audio data is stored in", .merge = .none },
    .{ .name = "subtitle-codec", .flag = 2, .t = t0, .nick = "subtitle codec", .blurb = "codec the subtitle data is stored in", .merge = .none },
    .{ .name = "container-format", .flag = 2, .t = t0, .nick = "container format", .blurb = "container format the data is stored in", .merge = .none },
    .{ .name = "bitrate", .flag = 2, .t = t3, .nick = "bitrate", .blurb = "exact or average bitrate in bits/s", .merge = .none },
    .{ .name = "nominal-bitrate", .flag = 2, .t = t3, .nick = "nominal bitrate", .blurb = "nominal bitrate in bits/s", .merge = .none },
    .{ .name = "minimum-bitrate", .flag = 2, .t = t3, .nick = "minimum bitrate", .blurb = "minimum bitrate in bits/s", .merge = .none },
    .{ .name = "maximum-bitrate", .flag = 2, .t = t3, .nick = "maximum bitrate", .blurb = "maximum bitrate in bits/s", .merge = .none },
    .{ .name = "serial", .flag = 2, .t = t3, .nick = "serial", .blurb = "serial number of track", .merge = .none },
    .{ .name = "encoder", .flag = 2, .t = t0, .nick = "encoder", .blurb = "encoder used to encode this stream", .merge = .none },
    .{ .name = "encoder-version", .flag = 2, .t = t3, .nick = "encoder version", .blurb = "version of the encoder used to encode this stream", .merge = .none },
    .{ .name = "replaygain-track-gain", .flag = 1, .t = t5, .nick = "replaygain track gain", .blurb = "track gain in dB", .merge = .none },
    .{ .name = "r128-track-gain", .flag = 1, .t = t5, .nick = "r128 track gain", .blurb = "track gain in dB (r128)", .merge = .none },
    .{ .name = "replaygain-track-peak", .flag = 1, .t = t5, .nick = "replaygain track peak", .blurb = "peak of the track", .merge = .none },
    .{ .name = "replaygain-album-gain", .flag = 1, .t = t5, .nick = "replaygain album gain", .blurb = "album gain in dB", .merge = .none },
    .{ .name = "r128-album-gain", .flag = 1, .t = t5, .nick = "r128 album gain", .blurb = "album gain in dB (r128)", .merge = .none },
    .{ .name = "replaygain-album-peak", .flag = 1, .t = t5, .nick = "replaygain album peak", .blurb = "peak of the album", .merge = .none },
    .{ .name = "replaygain-reference-level", .flag = 1, .t = t5, .nick = "replaygain reference level", .blurb = "reference level of track and album gain values", .merge = .none },
    .{ .name = "language-code", .flag = 1, .t = t0, .nick = "language code", .blurb = "language code for this stream, conforming to ISO-639-1 or ISO-639-2", .merge = .none },
    .{ .name = "language-name", .flag = 1, .t = t0, .nick = "language name", .blurb = "freeform name of the language this stream is in", .merge = .none },
    .{ .name = "image", .flag = 1, .t = t6, .nick = "image", .blurb = "image related to this stream", .merge = .first },
    .{ .name = "preview-image", .flag = 1, .t = t6, .nick = "preview image", .blurb = "preview image related to this stream", .merge = .none },
    .{ .name = "attachment", .flag = 1, .t = t6, .nick = "attachment", .blurb = "file attached to this stream", .merge = .first },
    .{ .name = "beats-per-minute", .flag = 1, .t = t5, .nick = "beats per minute", .blurb = "number of beats per minute in audio", .merge = .none },
    .{ .name = "keywords", .flag = 1, .t = t0, .nick = "keywords", .blurb = "comma separated keywords describing the content", .merge = .comma },
    .{ .name = "geo-location-name", .flag = 1, .t = t0, .nick = "geo location name", .blurb = "human readable descriptive location of where the media has been recorded or produced", .merge = .none },
    .{ .name = "geo-location-latitude", .flag = 1, .t = t5, .nick = "geo location latitude", .blurb = "geo latitude location of where the media has been recorded or produced in degrees according to WGS84 (zero at the equator, negative values for southern latitudes)", .merge = .none },
    .{ .name = "geo-location-longitude", .flag = 1, .t = t5, .nick = "geo location longitude", .blurb = "geo longitude location of where the media has been recorded or produced in degrees according to WGS84 (zero at the prime meridian in Greenwich/UK,  negative values for western longitudes)", .merge = .none },
    .{ .name = "geo-location-elevation", .flag = 1, .t = t5, .nick = "geo location elevation", .blurb = "geo elevation of where the media has been recorded or produced in meters according to WGS84 (zero is average sea level)", .merge = .none },
    .{ .name = "geo-location-country", .flag = 1, .t = t0, .nick = "geo location country", .blurb = "country (english name) where the media has been recorded or produced", .merge = .none },
    .{ .name = "geo-location-city", .flag = 1, .t = t0, .nick = "geo location city", .blurb = "city (english name) where the media has been recorded or produced", .merge = .none },
    .{ .name = "geo-location-sublocation", .flag = 1, .t = t0, .nick = "geo location sublocation", .blurb = "a location within a city where the media has been produced or created (e.g. the neighborhood)", .merge = .none },
    .{ .name = "geo-location-horizontal-error", .flag = 1, .t = t5, .nick = "geo location horizontal error", .blurb = "expected error of the horizontal positioning measures (in meters)", .merge = .none },
    .{ .name = "geo-location-movement-speed", .flag = 1, .t = t5, .nick = "geo location movement speed", .blurb = "movement speed of the capturing device while performing the capture in m/s", .merge = .none },
    .{ .name = "geo-location-movement-direction", .flag = 1, .t = t5, .nick = "geo location movement direction", .blurb = "indicates the movement direction of the device performing the capture of a media. It is represented as degrees in floating point representation, 0 means the geographic north, and increases clockwise", .merge = .none },
    .{ .name = "geo-location-capture-direction", .flag = 1, .t = t5, .nick = "geo location capture direction", .blurb = "indicates the direction the device is pointing to when capturing  a media. It is represented as degrees in floating point  representation, 0 means the geographic north, and increases clockwise", .merge = .none },
    .{ .name = "show-name", .flag = 1, .t = t0, .nick = "show name", .blurb = "Name of the tv/podcast/series show the media is from", .merge = .comma },
    .{ .name = "show-sortname", .flag = 1, .t = t0, .nick = "show sortname", .blurb = "Name of the tv/podcast/series show the media is from, for sorting purposes", .merge = .none },
    .{ .name = "show-episode-number", .flag = 1, .t = t3, .nick = "episode number", .blurb = "The episode number in the season the media is part of", .merge = .first },
    .{ .name = "show-season-number", .flag = 1, .t = t3, .nick = "season number", .blurb = "The season number of the show the media is part of", .merge = .first },
    .{ .name = "lyrics", .flag = 1, .t = t0, .nick = "lyrics", .blurb = "The lyrics of the media, commonly used for songs", .merge = .comma },
    .{ .name = "composer-sortname", .flag = 1, .t = t0, .nick = "composer sortname", .blurb = "person(s) who composed the recording, for sorting purposes", .merge = .none },
    .{ .name = "grouping", .flag = 1, .t = t0, .nick = "grouping", .blurb = "Groups related media that spans multiple tracks, like the different pieces of a concerto. It is a higher level than a track, but lower than an album", .merge = .none },
    .{ .name = "user-rating", .flag = 1, .t = t3, .nick = "user rating", .blurb = "Rating attributed by a user. The higher the rank, the more the user likes this media", .merge = .none },
    .{ .name = "device-manufacturer", .flag = 1, .t = t0, .nick = "device manufacturer", .blurb = "Manufacturer of the device used to create this media", .merge = .none },
    .{ .name = "device-model", .flag = 1, .t = t0, .nick = "device model", .blurb = "Model of the device used to create this media", .merge = .none },
    .{ .name = "application-name", .flag = 1, .t = t0, .nick = "application name", .blurb = "Application used to create the media", .merge = .none },
    .{ .name = "application-data", .flag = 1, .t = t6, .nick = "application data", .blurb = "Arbitrary application data to be serialized into the media", .merge = .none },
    .{ .name = "image-orientation", .flag = 1, .t = t0, .nick = "image orientation", .blurb = "How the image should be rotated or flipped before display", .merge = .none },
    .{ .name = "publisher", .flag = 1, .t = t0, .nick = "publisher", .blurb = "Name of the label or publisher", .merge = .comma },
    .{ .name = "interpreted-by", .flag = 1, .t = t0, .nick = "interpreted-by", .blurb = "Information about the people behind a remix and similar interpretations", .merge = .comma },
    .{ .name = "midi-base-note", .flag = 1, .t = t3, .nick = "midi-base-note", .blurb = "Midi note number of the audio track.", .merge = .none },
    .{ .name = "private-data", .flag = 1, .t = t6, .nick = "private-data", .blurb = "Private data", .merge = .first },
    .{ .name = "container-specific-track-id", .flag = 1, .t = t0, .nick = "container-specific-track-id", .blurb = "Container-specific Track ID", .merge = .none },
};
