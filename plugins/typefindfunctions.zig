const std = @import("std");
const cm = @import("common.zig");
const c = cm.c;
const build = @import("build_options");
const text = @import("typefind/text.zig");
const audio = @import("typefind/audio.zig");
const video = @import("typefind/video.zig");
const container = @import("typefind/container.zig");
const misc = @import("typefind/misc.zig");

const Find = *const fn ([*c]c.GstTypeFind, ?*anyopaque) callconv(.c) void;

const Entry = struct {
    name: [:0]const u8,
    rank: c.guint,
    func: ?Find,
    ext: ?[:0]const u8,
    caps: ?[:0]const u8 = null,
    data: ?[]const u8 = null,
    size: c.guint = 0,
    prob: c.guint = 0,
};

const entries = [_]Entry{
    .{ .name = "video/x-4xm", .rank = 256, .func = misc.riff, .ext = null, .data = "\x34\x58\x4d\x56", .size = 4, .prob = 100 },
    .{ .name = "video/x-msvideo", .rank = 256, .func = misc.riff, .ext = "avi", .data = "\x41\x56\x49\x20", .size = 4, .prob = 100 },
    .{ .name = "audio/qcelp", .rank = 256, .func = misc.riff, .ext = "qcp", .data = "\x51\x4c\x43\x4d", .size = 4, .prob = 100 },
    .{ .name = "video/x-cdxa", .rank = 256, .func = misc.riff, .ext = "dat", .data = "\x43\x44\x58\x41", .size = 4, .prob = 100 },
    .{ .name = "audio/riff-midi", .rank = 256, .func = misc.riff, .ext = "mid,midi", .data = "\x52\x4d\x49\x44", .size = 4, .prob = 100 },
    .{ .name = "audio/x-wav", .rank = 256, .func = misc.riff, .ext = "wav", .data = "\x57\x41\x56\x45", .size = 4, .prob = 100 },
    .{ .name = "image/webp", .rank = 256, .func = misc.riff, .ext = "webp", .data = "\x57\x45\x42\x50", .size = 4, .prob = 100 },
    .{ .name = "audio/x-xwma", .rank = 256, .func = misc.riff, .ext = null, .data = "\x58\x57\x4d\x41", .size = 4, .prob = 100 },
    .{ .name = "video/x-ms-asf", .rank = 128, .func = misc.startWith, .ext = "asf,wm,wma,wmv", .data = "\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c", .size = 16, .prob = 100 },
    .{ .name = "video/x-avs", .rank = 128, .func = misc.startWith, .ext = null, .data = "\x77\x57\x10\x00", .size = 4, .prob = 80 },
    .{ .name = "video/x-vcd", .rank = 256, .func = misc.startWith, .ext = "dat", .data = "\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00", .size = 12, .prob = 100 },
    .{ .name = "audio/x-imelody", .rank = 256, .func = misc.startWith, .ext = "imy,ime,imelody", .data = "\x42\x45\x47\x49\x4e\x3a\x49\x4d\x45\x4c\x4f\x44\x59", .size = 13, .prob = 100 },
    .{ .name = "application/x-scc", .rank = 256, .func = misc.startWith, .ext = "scc", .data = "\x53\x63\x65\x6e\x61\x72\x69\x73\x74\x5f\x53\x43\x43\x20\x56\x31\x2e\x30", .size = 18, .prob = 100 },
    .{ .name = "application/vnd.rn-realmedia", .rank = 128, .func = misc.startWith, .ext = "ra,ram,rm,rmvb", .data = "\x2e\x52\x4d\x46", .size = 4, .prob = 100 },
    .{ .name = "application/x-pn-realaudio", .rank = 128, .func = misc.startWith, .ext = "ra,ram,rm,rmvb", .data = "\x2e\x72\x61\xfd", .size = 4, .prob = 100 },
    .{ .name = "video/x-flv", .rank = 128, .func = misc.startWith, .ext = "flv", .data = "\x46\x4c\x56", .size = 3, .prob = 100 },
    .{ .name = "audio/x-nist", .rank = 128, .func = misc.startWith, .ext = "nist", .data = "\x4e\x49\x53\x54", .size = 4, .prob = 100 },
    .{ .name = "audio/x-voc", .rank = 128, .func = misc.startWith, .ext = "voc", .data = "\x43\x72\x65\x61\x74\x69\x76\x65", .size = 8, .prob = 100 },
    .{ .name = "audio/x-w64", .rank = 128, .func = misc.startWith, .ext = "w64", .data = "\x72\x69\x66\x66", .size = 4, .prob = 100 },
    .{ .name = "audio/x-rf64", .rank = 256, .func = misc.startWith, .ext = "rf64", .data = "\x52\x46\x36\x34", .size = 4, .prob = 100 },
    .{ .name = "image/gif", .rank = 256, .func = misc.startWith, .ext = "gif", .data = "\x47\x49\x46\x38", .size = 4, .prob = 100 },
    .{ .name = "image/png", .rank = 270, .func = misc.startWith, .ext = "png", .data = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a", .size = 8, .prob = 100 },
    .{ .name = "video/x-mve", .rank = 128, .func = misc.startWith, .ext = "mve", .data = "\x49\x6e\x74\x65\x72\x70\x6c\x61\x79\x20\x4d\x56\x45\x20\x46\x69\x6c\x65\x1a\x00\x1a\x00\x00\x01\x33\x11", .size = 26, .prob = 100 },
    .{ .name = "audio/x-amr-nb-sh", .rank = 256, .func = misc.startWith, .ext = "amr", .data = "\x23\x21\x41\x4d\x52", .size = 5, .prob = 80 },
    .{ .name = "audio/x-amr-wb-sh", .rank = 256, .func = misc.startWith, .ext = "amr", .data = "\x23\x21\x41\x4d\x52\x2d\x57\x42", .size = 7, .prob = 100 },
    .{ .name = "audio/x-sid", .rank = 64, .func = misc.startWith, .ext = "sid", .data = "\x50\x53\x49\x44", .size = 4, .prob = 100 },
    .{ .name = "image/x-xcf", .rank = 128, .func = misc.startWith, .ext = "xcf", .data = "\x67\x69\x6d\x70\x20\x78\x63\x66", .size = 8, .prob = 100 },
    .{ .name = "video/x-mng", .rank = 128, .func = misc.startWith, .ext = "mng", .data = "\x8a\x4d\x4e\x47\x0d\x0a\x1a\x0a", .size = 8, .prob = 100 },
    .{ .name = "image/x-jng", .rank = 128, .func = misc.startWith, .ext = "jng", .data = "\x8b\x4a\x4e\x47\x0d\x0a\x1a\x0a", .size = 8, .prob = 100 },
    .{ .name = "image/x-xpixmap", .rank = 128, .func = misc.startWith, .ext = "xpm", .data = "\x2f\x2a\x20\x58\x50\x4d\x20\x2a\x2f", .size = 9, .prob = 100 },
    .{ .name = "image/x-sun-raster", .rank = 128, .func = misc.startWith, .ext = "ras", .data = "\x59\xa6\x6a\x95", .size = 4, .prob = 100 },
    .{ .name = "application/x-bzip", .rank = 128, .func = misc.startWith, .ext = "bz2", .data = "\x42\x5a\x68", .size = 3, .prob = 80 },
    .{ .name = "application/x-gzip", .rank = 128, .func = misc.startWith, .ext = "gz", .data = "\x1f\x8b", .size = 2, .prob = 80 },
    .{ .name = "application/zip", .rank = 128, .func = misc.startWith, .ext = "zip", .data = "\x50\x4b\x03\x04", .size = 4, .prob = 80 },
    .{ .name = "application/x-compress", .rank = 128, .func = misc.startWith, .ext = "Z", .data = "\x1f\x9d", .size = 2, .prob = 80 },
    .{ .name = "application/x-executable", .rank = 64, .func = misc.startWith, .ext = null, .data = "\x7f\x45\x4c\x46", .size = 4, .prob = 100 },
    .{ .name = "audio/x-spc", .rank = 128, .func = misc.startWith, .ext = "spc", .data = "\x53\x4e\x45\x53\x2d\x53\x50\x43\x37\x30\x30\x20\x53\x6f\x75\x6e\x64\x20\x46\x69\x6c\x65\x20\x44\x61\x74\x61", .size = 27, .prob = 100 },
    .{ .name = "audio/x-caf", .rank = 128, .func = misc.startWith, .ext = "caf", .data = "\x63\x61\x66\x66\x00\x01", .size = 6, .prob = 100 },
    .{ .name = "application/x-rar", .rank = 128, .func = misc.startWith, .ext = "rar", .data = "\x52\x61\x72\x21", .size = 4, .prob = 80 },
    .{ .name = "audio/x-nsf", .rank = 128, .func = misc.startWith, .ext = "nsf", .data = "\x4e\x45\x53\x4d\x1a", .size = 5, .prob = 100 },
    .{ .name = "audio/x-gym", .rank = 128, .func = misc.startWith, .ext = "gym", .data = "\x47\x59\x4d\x58", .size = 4, .prob = 100 },
    .{ .name = "audio/x-ay", .rank = 128, .func = misc.startWith, .ext = "ay", .data = "\x5a\x58\x41\x59\x45\x4d\x55\x4c", .size = 8, .prob = 100 },
    .{ .name = "audio/x-gbs", .rank = 128, .func = misc.startWith, .ext = "gbs", .data = "\x47\x42\x53\x01", .size = 4, .prob = 100 },
    .{ .name = "audio/x-vgm", .rank = 128, .func = misc.startWith, .ext = "vgm", .data = "\x56\x67\x6d\x20", .size = 4, .prob = 100 },
    .{ .name = "audio/x-sap", .rank = 128, .func = misc.startWith, .ext = "sap", .data = "\x53\x41\x50\x0d\x0a\x41\x55\x54\x48\x4f\x52\x20", .size = 12, .prob = 100 },
    .{ .name = "video/x-ivf", .rank = 128, .func = misc.startWith, .ext = "ivf", .data = "\x44\x4b\x49\x46", .size = 4, .prob = 99 },
    .{ .name = "audio/x-kss", .rank = 128, .func = misc.startWith, .ext = "kss", .data = "\x4b\x53\x53\x58\x00", .size = 5, .prob = 100 },
    .{ .name = "application/pdf", .rank = 128, .func = misc.startWith, .ext = "pdf", .data = "\x25\x50\x44\x46\x2d", .size = 5, .prob = 80 },
    .{ .name = "application/msword", .rank = 128, .func = misc.startWith, .ext = "doc", .data = "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", .size = 8, .prob = 80 },
    .{ .name = "application/octet-stream", .rank = 128, .func = misc.startWith, .ext = "DS_Store", .data = "\x00\x00\x00\x01\x42\x75\x64\x31", .size = 8, .prob = 80 },
    .{ .name = "image/vnd.adobe.photoshop", .rank = 128, .func = misc.startWith, .ext = "psd", .data = "\x38\x42\x50\x53\x00\x01\x00\x00\x00\x00", .size = 10, .prob = 80 },
    .{ .name = "audio/x-xi", .rank = 128, .func = misc.startWith, .ext = "xi", .data = "\x45\x78\x74\x65\x6e\x64\x65\x64\x20\x49\x6e\x73\x74\x72\x75\x6d\x65\x6e\x74\x3a\x20", .size = 21, .prob = 100 },
    .{ .name = "audio/x-tap-dmp", .rank = 128, .func = misc.startWith, .ext = "dmp", .data = "\x44\x43\x32\x4e\x2d\x54\x41\x50\x2d\x52\x41\x57", .size = 12, .prob = 80 },
    .{ .name = "audio/x-musepack", .rank = 256, .func = audio.musepack, .ext = "mpc,mpp,mp+", .caps = "audio/x-musepack, streamversion= (int) { 7, 8 }" },
    .{ .name = "audio/x-au", .rank = 64, .func = misc.au, .ext = "au,snd", .caps = "audio/x-au" },
    .{ .name = "application/x-mcc", .rank = 256, .func = misc.mcc, .ext = "mcc", .caps = "application/x-mcc" },
    .{ .name = "audio/midi", .rank = 256, .func = text.mid, .ext = "mid,midi", .caps = "audio/midi" },
    .{ .name = "audio/mobile-xmf", .rank = 256, .func = text.mxmf, .ext = "mxmf", .caps = "audio/mobile-xmf" },
    .{ .name = "video/x-fli", .rank = 64, .func = text.flx, .ext = "flc,fli", .caps = "video/x-fli" },
    .{ .name = "application/x-id3v2", .rank = 359, .func = text.id3v2, .ext = "mp3,mp2,mp1,mpga,ogg,flac,tta", .caps = "application/x-id3" },
    .{ .name = "application/x-id3v1", .rank = 357, .func = text.id3v1, .ext = "mp3,mp2,mp1,mpga,ogg,flac,tta", .caps = "application/x-id3" },
    .{ .name = "application/x-apetag", .rank = 358, .func = text.apetag, .ext = "mp3,ape,mpc,wv", .caps = "application/x-apetag" },
    .{ .name = "audio/x-ttafile", .rank = 256, .func = text.tta, .ext = "tta", .caps = "audio/x-ttafile" },
    .{ .name = "audio/x-mod", .rank = 128, .func = container.mod, .ext = "669,amf,ams,dbm,digi,dmf,dsm,gdm,far,imf,it,j2b,mdl,med,mod,mt2,mtm,okt,psm,ptm,sam,s3m,stm,stx,ult,umx,xm", .caps = "audio/x-mod" },
    .{ .name = "audio/mpeg", .rank = 256, .func = audio.mp3, .ext = "mp3,mp2,mp1,mpga", .caps = "audio/mpeg, mpegversion = (int) 1, layer = (int) [ 1, 3 ]" },
    .{ .name = "audio/x-ac3", .rank = 256, .func = audio.ac3, .ext = "ac3,eac3", .caps = "audio/x-ac3" },
    .{ .name = "audio/x-dts", .rank = 128, .func = audio.dts, .ext = "dts", .caps = "audio/x-dts" },
    .{ .name = "audio/x-gsm", .rank = 256, .func = null, .ext = "gsm", .caps = "audio/x-gsm, rate=8000, channels=1" },
    .{ .name = "video/mpeg-sys", .rank = 256, .func = video.mpegSys, .ext = "mpe,mpeg,mpg", .caps = "video/mpeg, systemstream = (boolean) true, mpegversion = (int) [ 1, 2 ]" },
    .{ .name = "video/mpegts", .rank = 256, .func = video.mpegTs, .ext = "ts,mts", .caps = "video/mpegts, systemstream = (boolean) true, packetsize = (int) [ 188, 208 ]" },
    .{ .name = "application/ogg", .rank = 256, .func = container.ogg, .ext = "ogg,oga,ogv,ogm,ogx,spx,anx,axa,axv", .caps = "application/ogg;video/ogg;audio/ogg;application/kate" },
    .{ .name = "video/mpeg-elementary", .rank = 64, .func = video.mpegVideo, .ext = "mpv,mpeg,mpg", .caps = "video/mpeg, systemstream = (boolean) false" },
    .{ .name = "video/mpeg4", .rank = 256, .func = video.mpeg4, .ext = "m4v", .caps = "video/mpeg, systemstream = (boolean) false" },
    .{ .name = "video/x-h263", .rank = 128, .func = video.h263, .ext = "h263,263", .caps = "video/x-h263, variant=(string)itu" },
    .{ .name = "video/x-h264", .rank = 256, .func = video.h264, .ext = "h264,x264,264", .caps = "video/x-h264,stream-format=byte-stream" },
    .{ .name = "video/x-h265", .rank = 256, .func = video.h265, .ext = "h265,x265,265", .caps = "video/x-h265,stream-format=byte-stream" },
    .{ .name = "video/x-h266", .rank = 256, .func = video.h266, .ext = "h266,266", .caps = "video/x-h266,stream-format=byte-stream" },
    .{ .name = "video/x-nuv", .rank = 128, .func = misc.nuv, .ext = "nuv", .caps = "video/x-nuv" },
    .{ .name = "audio/x-m4a", .rank = 256, .func = container.m4a, .ext = "m4a", .caps = "audio/x-m4a" },
    .{ .name = "application/x-3gp", .rank = 256, .func = container.q3gp, .ext = "3gp", .caps = "application/x-3gp" },
    .{ .name = "video/quicktime", .rank = 256, .func = container.qt, .ext = "mov,mp4", .caps = "video/quicktime" },
    .{ .name = "image/x-quicktime", .rank = 128, .func = container.qtif, .ext = "qif,qtif,qti", .caps = "image/x-quicktime" },
    .{ .name = "image/jp2", .rank = 256, .func = container.jp2, .ext = "jp2", .caps = "image/jp2" },
    .{ .name = "image/x-jpc", .rank = 256, .func = container.jpc, .ext = "jpc,j2k", .caps = "image/x-jpc" },
    .{ .name = "video/mj2", .rank = 256, .func = container.jp2, .ext = "mj2", .caps = "video/mj2" },
    .{ .name = "text/html", .rank = 128, .func = text.html, .ext = "htm,html", .caps = "text/html" },
    .{ .name = "application/x-shockwave-flash", .rank = 128, .func = container.swf, .ext = "swf,swfl", .caps = "application/x-shockwave-flash" },
    .{ .name = "application/xges", .rank = 256, .func = text.xges, .ext = "xges", .caps = "application/xges" },
    .{ .name = "application/vnd.apple-xmeml+xml", .rank = 128, .func = text.xmeml, .ext = "xmeml", .caps = "application/vnd.apple-xmeml+xml" },
    .{ .name = "application/vnd.apple-fcp+xml", .rank = 128, .func = text.fcpxml, .ext = "fcpxml", .caps = "application/vnd.apple-fcp+xml" },
    .{ .name = "application/vnd.pixar.opentimelineio+json", .rank = 128, .func = text.otio, .ext = "otio", .caps = "application/vnd.pixar.opentimelineio+json" },
    .{ .name = "application/dash+xml", .rank = 256, .func = text.dash, .ext = "mpd,MPD", .caps = "application/dash+xml" },
    .{ .name = "application/vnd.ms-sstr+xml", .rank = 256, .func = container.mss, .ext = null, .caps = "application/vnd.ms-sstr+xml" },
    .{ .name = "text/plain", .rank = 64, .func = text.utf8, .ext = "txt", .caps = "text/plain" },
    .{ .name = "text/utf-16", .rank = 64, .func = text.utf16, .ext = "txt", .caps = "text/utf-16" },
    .{ .name = "text/utf-32", .rank = 64, .func = text.utf32, .ext = "txt", .caps = "text/utf-32" },
    .{ .name = "text/uri-list", .rank = 64, .func = text.uri, .ext = "ram", .caps = "text/uri-list" },
    .{ .name = "application/itc", .rank = 128, .func = text.itc, .ext = "itc", .caps = "application/itc" },
    .{ .name = "application/x-hls", .rank = 64, .func = text.hls, .ext = "m3u8", .caps = "application/x-hls" },
    .{ .name = "application/sdp", .rank = 128, .func = text.sdp, .ext = "sdp", .caps = "application/sdp" },
    .{ .name = "application/smil", .rank = 128, .func = text.smil, .ext = "smil", .caps = "application/smil" },
    .{ .name = "application/ttml+xml", .rank = 128, .func = text.ttml, .ext = "ttml+xml", .caps = "application/ttml+xml" },
    .{ .name = "application/xml", .rank = 64, .func = text.xml, .ext = "xml", .caps = "application/xml" },
    .{ .name = "audio/x-aiff", .rank = 128, .func = container.aiff, .ext = "aiff,aif,aifc", .caps = "audio/x-aiff" },
    .{ .name = "audio/x-svx", .rank = 128, .func = container.svx, .ext = "iff,svx", .caps = "audio/x-svx" },
    .{ .name = "audio/x-paris", .rank = 128, .func = misc.paris, .ext = "paf", .caps = "audio/x-paris" },
    .{ .name = "audio/x-sds", .rank = 128, .func = container.sds, .ext = "sds", .caps = "audio/x-sds" },
    .{ .name = "audio/x-ircam", .rank = 128, .func = container.ircam, .ext = "sf", .caps = "audio/x-ircam" },
    .{ .name = "audio/x-shorten", .rank = 128, .func = container.shn, .ext = "shn", .caps = "audio/x-shorten" },
    .{ .name = "application/x-ape", .rank = 128, .func = container.ape, .ext = "ape", .caps = "application/x-ape" },
    .{ .name = "image/jpeg", .rank = 271, .func = container.jpeg, .ext = "jpg,jpe,jpeg", .caps = "image/jpeg" },
    .{ .name = "image/bmp", .rank = 256, .func = container.bmp, .ext = "bmp", .caps = "image/bmp" },
    .{ .name = "image/tiff", .rank = 256, .func = container.tiff, .ext = "tif,tiff", .caps = "image/tiff, endianness = (int) { BIG_ENDIAN, LITTLE_ENDIAN }" },
    .{ .name = "image/x-exr", .rank = 256, .func = container.exr, .ext = "exr", .caps = "image/x-exr" },
    .{ .name = "image/x-portable-pixmap", .rank = 128, .func = container.pnm, .ext = "pnm,ppm,pgm,pbm", .caps = "image/x-portable-bitmap; image/x-portable-graymap; image/x-portable-pixmap; image/x-portable-anymap" },
    .{ .name = "video/x-matroska", .rank = 256, .func = container.matroska, .ext = "mkv,mka,mk3d,webm", .caps = "video/x-matroska" },
    .{ .name = "application/mxf", .rank = 256, .func = container.mxf, .ext = "mxf", .caps = "application/mxf" },
    .{ .name = "video/x-dv", .rank = 128, .func = container.dv, .ext = "dv,dif", .caps = "video/x-dv, systemstream = (boolean) true" },
    .{ .name = "audio/iLBC-sh", .rank = 256, .func = misc.ilbc, .ext = "ilbc", .caps = "audio/iLBC-sh" },
    .{ .name = "audio/x-sbc", .rank = 64, .func = misc.sbc, .ext = "sbc", .caps = "audio/x-sbc" },
    .{ .name = "subtitle/x-kate", .rank = 64, .func = container.kate, .ext = null, .caps = null },
    .{ .name = "application/x-subtitle-vtt", .rank = 64, .func = container.webvtt, .ext = "vtt", .caps = "application/x-subtitle-vtt, parsed=(boolean)false" },
    .{ .name = "audio/x-flac", .rank = 256, .func = text.flac, .ext = "flac", .caps = "audio/x-flac" },
    .{ .name = "audio/x-vorbis", .rank = 256, .func = container.vorbis, .ext = null, .caps = "audio/x-vorbis" },
    .{ .name = "video/x-theora", .rank = 256, .func = container.theora, .ext = null, .caps = "video/x-theora" },
    .{ .name = "application/x-ogm-video", .rank = 256, .func = misc.ogmvideo, .ext = null, .caps = "application/x-ogm-video" },
    .{ .name = "application/x-ogm-audio", .rank = 256, .func = misc.ogmaudio, .ext = null, .caps = "application/x-ogm-audio" },
    .{ .name = "application/x-ogm-text", .rank = 256, .func = misc.ogmtext, .ext = null, .caps = "application/x-ogm-text" },
    .{ .name = "audio/x-speex", .rank = 256, .func = misc.speex, .ext = null, .caps = "audio/x-speex" },
    .{ .name = "audio/x-celt", .rank = 256, .func = misc.celt, .ext = null, .caps = "audio/x-celt" },
    .{ .name = "application/x-ogg-skeleton", .rank = 256, .func = misc.oggskel, .ext = null, .caps = "application/x-ogg-skeleton, parsed=(boolean)FALSE" },
    .{ .name = "text/x-cmml", .rank = 256, .func = misc.cmml, .ext = null, .caps = "text/x-cmml" },
    .{ .name = "audio/aac", .rank = 128, .func = audio.aac, .ext = "aac,adts,adif,loas", .caps = "audio/mpeg, mpegversion = (int) { 2, 4 }, framed = (bool) false" },
    .{ .name = "audio/x-wavpack", .rank = 128, .func = audio.wavpack, .ext = "wv,wvp", .caps = "audio/x-wavpack, framed = (boolean) false" },
    .{ .name = "audio/x-wavpack-correction", .rank = 128, .func = audio.wavpack, .ext = "wvc", .caps = "audio/x-wavpack-correction, framed = (boolean) false" },
    .{ .name = "application/postscript", .rank = 128, .func = misc.postscript, .ext = "ps", .caps = "application/postscript" },
    .{ .name = "image/svg+xml", .rank = 128, .func = misc.svg, .ext = "svg", .caps = "image/svg+xml" },
    .{ .name = "application/x-tar", .rank = 128, .func = misc.tar, .ext = "tar", .caps = "application/x-tar" },
    .{ .name = "application/x-ar", .rank = 128, .func = misc.ar, .ext = "a", .caps = "application/x-ar" },
    .{ .name = "application/x-ms-dos-executable", .rank = 128, .func = misc.msdos, .ext = "dll,exe,ocx,sys,scr,msstyles,cpl", .caps = "application/x-ms-dos-executable" },
    .{ .name = "video/x-dirac", .rank = 256, .func = misc.dirac, .ext = null, .caps = "video/x-dirac" },
    .{ .name = "multipart/x-mixed-replace", .rank = 128, .func = misc.multipart, .ext = null, .caps = "multipart/x-mixed-replace" },
    .{ .name = "application/x-mmsh", .rank = 128, .func = misc.mmsh, .ext = null, .caps = "application/x-mmsh" },
    .{ .name = "video/vivo", .rank = 128, .func = misc.vivo, .ext = "viv", .caps = "video/vivo" },
    .{ .name = "image/vnd.wap.wbmp", .rank = 64, .func = misc.wbmp, .ext = null, .caps = null },
    .{ .name = "application/x-yuv4mpeg", .rank = 256, .func = misc.y4m, .ext = "y4m", .caps = null },
    .{ .name = "image/x-icon", .rank = 64, .func = misc.windowsIcon, .ext = null, .caps = null },
    .{ .name = "image/x-degas", .rank = 64, .func = misc.degas, .ext = null, .caps = null },
    .{ .name = "application/octet-stream", .rank = 64, .func = misc.dvdiso, .ext = null, .caps = null },
    .{ .name = "application/x-ssa", .rank = 128, .func = misc.ssa, .ext = "ssa,ass", .caps = null },
    .{ .name = "video/x-pva", .rank = 128, .func = misc.pva, .ext = "pva", .caps = "video/x-pva" },
    .{ .name = "audio/audible", .rank = 64, .func = misc.aa, .ext = "aa,aax", .caps = "audio/x-audible" },
    .{ .name = "audio/x-tap-tap", .rank = 256, .func = misc.tap, .ext = "tap", .caps = "audio/x-tap-tap" },
    .{ .name = "audio/x-brstm", .rank = 128, .func = misc.brstm, .ext = "brstm", .caps = "audio/x-brstm" },
    .{ .name = "audio/x-bfstm", .rank = 128, .func = misc.bfstm, .ext = "bfstm,bcstm", .caps = "audio/x-bfstm" },
    .{ .name = "audio/x-dsf", .rank = 256, .func = misc.dsf, .ext = null, .caps = "audio/x-dsf" },
    .{ .name = "video/x-ea", .rank = 128, .func = misc.ea, .ext = null, .caps = "video/x-ea" },
    .{ .name = "video/x-film-cpk", .rank = 128, .func = misc.filmCpk, .ext = "cpk", .caps = "video/x-film-cpk" },
    .{ .name = "application/gxf", .rank = 128, .func = misc.gxf, .ext = null, .caps = "application/gxf" },
    .{ .name = "application/x-iff", .rank = 128, .func = misc.iff, .ext = null, .caps = "application/x-iff" },
    .{ .name = "video/x-av1", .rank = 64, .func = misc.av1, .ext = "av1", .caps = "video/x-av1,stream-format={obu-stream, annexb},alignment=none" },
};

fn staticCaps(comptime str: [:0]const u8) [*c]c.GstCaps {
    const S = struct {
        var v = c.GstStaticCaps{ .caps = null, .string = str.ptr, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    };
    return c.gst_static_caps_get(&S.v);
}

fn add(p: ?*c.GstPlugin, comptime e: Entry) void {
    const ext: [*c]const u8 = if (e.ext) |x| x.ptr else null;
    if (e.data) |bytes| {
        const sw: *misc.Data = @ptrCast(@alignCast(c.g_malloc(@sizeOf(misc.Data))));
        sw.* = .{ .data = bytes.ptr, .size = e.size, .prob = e.prob, .caps = c.gst_caps_new_empty_simple(e.name.ptr) };
        if (c.gst_type_find_register(p, e.name.ptr, e.rank, e.func, ext, sw.caps, sw, misc.destroy) == 0) misc.destroy(sw);
        return;
    }
    const caps: [*c]c.GstCaps = if (e.caps) |s| staticCaps(s) else null;
    _ = c.gst_type_find_register(p, e.name.ptr, e.rank, e.func, ext, caps, null, null);
}

fn pluginInit(p: ?*c.GstPlugin) callconv(.c) c.gboolean {
    _ = c._gst_debug_category_new("typefindfunctions", c.GST_DEBUG_FG_GREEN | c.GST_DEBUG_BG_RED, "generic type find functions");
    inline for (entries) |e| add(p, e);
    return 1;
}

var desc = c.GstPluginDesc{
    .major_version = 1,
    .minor_version = 28,
    .name = "typefindfunctions",
    .description = "default typefind functions",
    .plugin_init = pluginInit,
    .version = "1.28.2",
    .license = "LGPL",
    .source = "gst-plugins-base",
    .package = build.package ++ "",
    .origin = build.origin ++ "",
    .release_datetime = null,
    ._gst_reserved = std.mem.zeroes([4]c.gpointer),
};

pub export fn gst_plugin_typefindfunctions_get_desc() *const c.GstPluginDesc {
    return &desc;
}

pub export fn gst_plugin_typefindfunctions_register() void {
    _ = c.gst_plugin_register_static(desc.major_version, desc.minor_version, desc.name, desc.description, desc.plugin_init, desc.version, desc.license, desc.source, desc.package, desc.origin);
}
