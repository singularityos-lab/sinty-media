const std = @import("std");
const c = @import("../c.zig").c;
const read = @import("read.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const N: ?*anyopaque = null;
const MAXINT = std.math.maxInt(c.gint);

fn fcc(k: [4]u8) u32 {
    return std.mem.readInt(u32, &k, .little);
}

const Video = struct { fccs: []const u32, caps: [*:0]const u8, name: [*:0]const u8 };

const videos = [_]Video{
    .{ .fccs = &.{ fcc(.{ 'G', 'R', 'E', 'Y' }), fcc(.{ 'Y', '8', '0', '0' }), fcc(.{ 'Y', '8', ' ', ' ' }) }, .caps = "video/x-raw, format=(string)GRAY8", .name = "Uncompressed 8-bit monochrome" },
    .{ .fccs = &.{ fcc(.{ 'r', '2', '1', '0' }) }, .caps = "video/x-raw, format=(string)r210", .name = "Uncompressed packed RGB 10-bit 4:4:4" },
    .{ .fccs = &.{ c.GST_RIFF_I420, c.GST_RIFF_i420, c.GST_RIFF_IYUV }, .caps = "video/x-raw, format=(string)I420", .name = "Uncompressed planar YUV 4:2:0" },
    .{ .fccs = &.{ c.GST_RIFF_YUY2, c.GST_RIFF_yuy2, fcc(.{ 'Y', 'U', 'N', 'V' }), fcc(.{ 'Y', 'U', 'Y', 'V' }) }, .caps = "video/x-raw, format=(string)YUY2", .name = "Uncompressed packed YUV 4:2:2" },
    .{ .fccs = &.{ c.GST_RIFF_YVU9 }, .caps = "video/x-raw, format=(string)YVU9", .name = "Uncompressed packed YVU 4:1:0" },
    .{ .fccs = &.{ fcc(.{ 'U', 'Y', 'V', 'Y' }), fcc(.{ '2', 'v', 'u', 'y' }), fcc(.{ 'H', 'D', 'Y', 'C' }) }, .caps = "video/x-raw, format=(string)UYVY", .name = "Uncompressed packed YUV 4:2:2" },
    .{ .fccs = &.{ c.GST_RIFF_YV12, c.GST_RIFF_yv12 }, .caps = "video/x-raw, format=(string)YV12", .name = "Uncompressed packed YVU 4:2:2" },
    .{ .fccs = &.{ fcc(.{ 'v', '2', '1', '0' }) }, .caps = "video/x-raw, format=(string)v210", .name = "Uncompressed packed 10-bit YUV 4:2:2" },
    .{ .fccs = &.{ c.GST_RIFF_MJPG, c.GST_RIFF_mJPG, fcc(.{ 'A', 'V', 'R', 'n' }), c.GST_RIFF_IJPG, fcc(.{ 'i', 'j', 'p', 'g' }), c.GST_RIFF_DMB1, c.GST_RIFF_dmb1, fcc(.{ 'A', 'C', 'D', 'V' }), fcc(.{ 'Q', 'I', 'V', 'G' }) }, .caps = "image/jpeg, parsed=(boolean)true", .name = "Motion JPEG" },
    .{ .fccs = &.{ c.GST_RIFF_JPEG, c.GST_RIFF_jpeg, fcc(.{ 'j', 'p', 'e', 'g' }) }, .caps = "image/jpeg, parsed=(boolean)true", .name = "JPEG Still Image" },
    .{ .fccs = &.{ fcc(.{ 'P', 'I', 'X', 'L' }), c.GST_RIFF_VIXL, c.GST_RIFF_vixl }, .caps = "image/jpeg, parsed=(boolean)true", .name = "Miro/Pinnacle Motion JPEG" },
    .{ .fccs = &.{ fcc(.{ 'C', 'J', 'P', 'G' }) }, .caps = "image/jpeg, parsed=(boolean)true", .name = "Creative Webcam JPEG" },
    .{ .fccs = &.{ fcc(.{ 'S', 'L', 'M', 'J' }) }, .caps = "image/jpeg, parsed=(boolean)true", .name = "SL Motion JPEG" },
    .{ .fccs = &.{ fcc(.{ 'J', 'P', 'G', 'L' }) }, .caps = "image/jpeg, parsed=(boolean)true", .name = "Pegasus Lossless JPEG" },
    .{ .fccs = &.{ fcc(.{ 'L', 'O', 'C', 'O' }) }, .caps = "video/x-loco", .name = "LOCO Lossless" },
    .{ .fccs = &.{ fcc(.{ 'S', 'P', '5', '3' }), fcc(.{ 'S', 'P', '5', '4' }), fcc(.{ 'S', 'P', '5', '5' }), fcc(.{ 'S', 'P', '5', '6' }), fcc(.{ 'S', 'P', '5', '7' }), fcc(.{ 'S', 'P', '5', '8' }) }, .caps = "video/sp5x", .name = "Sp5x-like JPEG" },
    .{ .fccs = &.{ fcc(.{ 'Z', 'M', 'B', 'V' }) }, .caps = "video/x-zmbv", .name = "Zip Motion Block video" },
    .{ .fccs = &.{ fcc(.{ 'M', 'P', 'E', 'G' }), fcc(.{ 'M', 'P', 'G', 'I' }), fcc(.{ 'm', 'p', 'g', '1' }), fcc(.{ 'M', 'P', 'G', '1' }), fcc(.{ 'P', 'I', 'M', '1' }), fcc(.{ 1, 0, 0, 16 }) }, .caps = "video/mpeg, systemstream=(boolean)false, mpegversion=(int)1", .name = "MPEG-1 video" },
    .{ .fccs = &.{ fcc(.{ 'M', 'P', 'G', '2' }), fcc(.{ 'm', 'p', 'g', '2' }), fcc(.{ 'P', 'I', 'M', '2' }), fcc(.{ 'D', 'V', 'R', ' ' }), fcc(.{ 2, 0, 0, 16 }) }, .caps = "video/mpeg, systemstream=(boolean)false, mpegversion=(int)2", .name = "MPEG-2 video" },
    .{ .fccs = &.{ fcc(.{ 'L', 'M', 'P', '2' }) }, .caps = "video/mpeg, systemstream=(boolean)false, mpegversion=(int)2", .name = "Lead MPEG-2 video" },
    .{ .fccs = &.{ c.GST_RIFF_H263, c.GST_RIFF_h263, c.GST_RIFF_i263, fcc(.{ 'U', '2', '6', '3' }), fcc(.{ 'v', 'i', 'v', '1' }), fcc(.{ 'T', '2', '6', '3' }) }, .caps = "video/x-h263, variant=(string)itu", .name = "ITU H.26n" },
    .{ .fccs = &.{ c.GST_RIFF_L263 }, .caps = "video/x-h263, variant=(string)lead", .name = "Lead H.263" },
    .{ .fccs = &.{ c.GST_RIFF_M263, c.GST_RIFF_m263 }, .caps = "video/x-h263, variant=(string)microsoft", .name = "Microsoft H.263" },
    .{ .fccs = &.{ c.GST_RIFF_VDOW }, .caps = "video/x-h263, variant=(string)vdolive", .name = "VDOLive" },
    .{ .fccs = &.{ fcc(.{ 'V', 'I', 'V', 'O' }) }, .caps = "video/x-h263, variant=(string)vivo", .name = "Vivo H.263" },
    .{ .fccs = &.{ c.GST_RIFF_x263 }, .caps = "video/x-h263, variant=(string)xirlink", .name = "Xirlink H.263" },
    .{ .fccs = &.{ fcc(.{ 'I', '2', '6', '3' }) }, .caps = "video/x-intel-h263, variant=(string)intel", .name = "Intel H.263" },
    .{ .fccs = &.{ fcc(.{ 'V', 'X', '1', 'K' }) }, .caps = "video/x-h263, variant=(string)lucent", .name = "Lucent VX1000S H.263" },
    .{ .fccs = &.{ fcc(.{ 'X', '2', '6', '4' }), fcc(.{ 'x', '2', '6', '4' }), fcc(.{ 'H', '2', '6', '4' }), fcc(.{ 'h', '2', '6', '4' }), fcc(.{ 'a', 'v', 'c', '1' }), fcc(.{ 'A', 'V', 'C', '1' }) }, .caps = "video/x-h264, variant=(string)itu", .name = "ITU H.264" },
    .{ .fccs = &.{ fcc(.{ 'X', '2', '6', '5' }), fcc(.{ 'x', '2', '6', '5' }), fcc(.{ 'H', '2', '6', '5' }), fcc(.{ 'h', '2', '6', '5' }), fcc(.{ 'h', 'v', 'c', '1' }), fcc(.{ 'H', 'V', 'C', '1' }), fcc(.{ 'h', 'e', 'v', 'c' }), fcc(.{ 'H', 'E', 'V', 'C' }), fcc(.{ 'h', 'e', 'v', '1' }), fcc(.{ 'H', 'E', 'V', '1' }) }, .caps = "video/x-h265", .name = "H.265" },
    .{ .fccs = &.{ c.GST_RIFF_VSSH }, .caps = "video/x-h264, variant=(string)videosoft", .name = "VideoSoft H.264" },
    .{ .fccs = &.{ fcc(.{ 'L', '2', '6', '4' }) }, .caps = "video/x-h264, variant=(string)lead", .name = "Lead H.264" },
    .{ .fccs = &.{ fcc(.{ 'S', 'E', 'D', 'G' }) }, .caps = "video/mpeg, mpegversion=(int)4, systemstream=(boolean)false", .name = "Samsung MPEG-4" },
    .{ .fccs = &.{ fcc(.{ 'M', '4', 'C', 'C' }) }, .caps = "video/mpeg, mpegversion=(int)4, systemstream=(boolean)false", .name = "Divio MPEG-4" },
    .{ .fccs = &.{ c.GST_RIFF_DIV3, fcc(.{ 'd', 'i', 'v', '3' }), fcc(.{ 'D', 'V', 'X', '3' }), fcc(.{ 'd', 'v', 'x', '3' }), fcc(.{ 'D', 'I', 'V', '4' }), fcc(.{ 'd', 'i', 'v', '4' }), fcc(.{ 'D', 'I', 'V', '5' }), fcc(.{ 'd', 'i', 'v', '5' }), fcc(.{ 'D', 'I', 'V', '6' }), fcc(.{ 'd', 'i', 'v', '6' }), fcc(.{ 'M', 'P', 'G', '3' }), fcc(.{ 'm', 'p', 'g', '3' }), fcc(.{ 'c', 'o', 'l', '0' }), fcc(.{ 'C', 'O', 'L', '0' }), fcc(.{ 'c', 'o', 'l', '1' }), fcc(.{ 'C', 'O', 'L', '1' }), fcc(.{ 'A', 'P', '4', '1' }) }, .caps = "video/x-divx, divxversion=(int)3", .name = "DivX MS-MPEG-4 Version 3" },
    .{ .fccs = &.{ fcc(.{ 'd', 'i', 'v', 'x' }), fcc(.{ 'D', 'I', 'V', 'X' }) }, .caps = "video/x-divx, divxversion=(int)4", .name = "DivX MPEG-4 Version 4" },
    .{ .fccs = &.{ fcc(.{ 'B', 'L', 'Z', '0' }) }, .caps = "video/x-divx, divxversion=(int)4", .name = "Blizzard DivX" },
    .{ .fccs = &.{ fcc(.{ 'D', 'X', '5', '0' }) }, .caps = "video/x-divx, divxversion=(int)5", .name = "DivX MPEG-4 Version 5" },
    .{ .fccs = &.{ fcc(.{ 'M', 'P', 'G', '4' }), fcc(.{ 'M', 'P', '4', '1' }), fcc(.{ 'm', 'p', '4', '1' }) }, .caps = "video/x-msmpeg, msmpegversion=(int)41", .name = "Microsoft MPEG-4 4.1" },
    .{ .fccs = &.{ fcc(.{ 'm', 'p', '4', '2' }), fcc(.{ 'M', 'P', '4', '2' }) }, .caps = "video/x-msmpeg, msmpegversion=(int)42", .name = "Microsoft MPEG-4 4.2" },
    .{ .fccs = &.{ fcc(.{ 'm', 'p', '4', '3' }), fcc(.{ 'M', 'P', '4', '3' }) }, .caps = "video/x-msmpeg, msmpegversion=(int)43", .name = "Microsoft MPEG-4 4.3" },
    .{ .fccs = &.{ fcc(.{ 'M', 'P', '4', 'S' }), fcc(.{ 'M', '4', 'S', '2' }) }, .caps = "video/mpeg, mpegversion=(int)4, systemstream=(boolean)false", .name = "Microsoft ISO MPEG-4 1.1" },
    .{ .fccs = &.{ fcc(.{ 'F', 'M', 'P', '4' }), fcc(.{ 'U', 'M', 'P', '4' }), fcc(.{ 'F', 'F', 'D', 'S' }) }, .caps = "video/mpeg, mpegversion=(int)4, systemstream=(boolean)false", .name = "FFmpeg MPEG-4" },
    .{ .fccs = &.{ fcc(.{ '3', 'I', 'V', '1' }), fcc(.{ '3', 'I', 'V', '2' }), fcc(.{ 'X', 'V', 'I', 'D' }), fcc(.{ 'x', 'v', 'i', 'd' }), fcc(.{ 'E', 'M', '4', 'A' }), fcc(.{ 'E', 'P', 'V', 'H' }), fcc(.{ 'F', 'V', 'F', 'W' }), fcc(.{ 'I', 'N', 'M', 'C' }), fcc(.{ 'D', 'I', 'G', 'I' }), fcc(.{ 'D', 'M', '2', 'K' }), fcc(.{ 'D', 'C', 'O', 'D' }), fcc(.{ 'M', 'V', 'X', 'M' }), fcc(.{ 'P', 'M', '4', 'V' }), fcc(.{ 'S', 'M', 'P', '4' }), fcc(.{ 'D', 'X', 'G', 'M' }), fcc(.{ 'V', 'I', 'D', 'M' }), fcc(.{ 'M', '4', 'T', '3' }), fcc(.{ 'G', 'E', 'O', 'X' }), fcc(.{ 'M', 'P', '4', 'V' }), fcc(.{ 'm', 'p', '4', 'v' }), fcc(.{ 'R', 'M', 'P', '4' }) }, .caps = "video/mpeg, mpegversion=(int)4, systemstream=(boolean)false", .name = "MPEG-4" },
    .{ .fccs = &.{ fcc(.{ '3', 'i', 'v', 'd' }), fcc(.{ '3', 'I', 'V', 'D' }) }, .caps = "video/x-msmpeg, msmpegversion=(int)43", .name = "Microsoft MPEG-4 4.3" },
    .{ .fccs = &.{ fcc(.{ 'C', 'F', 'H', 'D' }) }, .caps = "video/x-cineform", .name = "CineForm" },
    .{ .fccs = &.{ fcc(.{ 'D', 'V', 'S', 'D' }), fcc(.{ 'd', 'v', 's', 'd' }), fcc(.{ 'd', 'v', 'c', ' ' }), fcc(.{ 'd', 'v', '2', '5' }) }, .caps = "video/x-dv, systemstream=(boolean)false, dvversion=(int)25", .name = "Generic DV" },
    .{ .fccs = &.{ fcc(.{ 'C', 'D', 'V', 'C' }), fcc(.{ 'c', 'd', 'v', 'c' }) }, .caps = "video/x-dv, systemstream=(boolean)false, dvversion=(int)25", .name = "Canopus DV" },
    .{ .fccs = &.{ fcc(.{ 'D', 'V', '5', '0' }), fcc(.{ 'd', 'v', '5', '0' }) }, .caps = "video/x-dv, systemstream=(boolean)false, dvversion=(int)50", .name = "DVCPro50 Video" },
    .{ .fccs = &.{ fcc(.{ 'M', 'S', 'S', '1' }) }, .caps = "video/x-wmv, wmvversion=(int)1, format=(string)MSS1", .name = "Microsoft Windows Media 7 Screen" },
    .{ .fccs = &.{ fcc(.{ 'M', 'S', 'S', '2' }) }, .caps = "video/x-wmv, wmvversion=(int)3, format=(string)MSS2", .name = "Microsoft Windows Media 9 Screen" },
    .{ .fccs = &.{ fcc(.{ 'W', 'M', 'V', '1' }) }, .caps = "video/x-wmv, wmvversion=(int)1", .name = "Microsoft Windows Media 7" },
    .{ .fccs = &.{ fcc(.{ 'W', 'M', 'V', '2' }) }, .caps = "video/x-wmv, wmvversion=(int)2", .name = "Microsoft Windows Media 8" },
    .{ .fccs = &.{ fcc(.{ 'W', 'M', 'V', '3' }) }, .caps = "video/x-wmv, wmvversion=(int)3, format=(string)WMV3", .name = "Microsoft Windows Media 9" },
    .{ .fccs = &.{ fcc(.{ 'W', 'M', 'V', 'A' }) }, .caps = "video/x-wmv, wmvversion=(int)3, format=(string)WMVA", .name = "Microsoft Windows Media Advanced Profile" },
    .{ .fccs = &.{ fcc(.{ 'W', 'V', 'C', '1' }) }, .caps = "video/x-wmv, wmvversion=(int)3, format=(string)WVC1", .name = "Microsoft Windows Media VC-1" },
    .{ .fccs = &.{ c.GST_RIFF_cvid, c.GST_RIFF_CVID }, .caps = "video/x-cinepak", .name = "Cinepak video" },
    .{ .fccs = &.{ fcc(.{ 'A', 'A', 'S', 'C' }) }, .caps = "video/x-aasc", .name = "Autodesk Animator" },
    .{ .fccs = &.{ fcc(.{ 'X', 'x', 'a', 'n' }) }, .caps = "video/x-xan, wcversion=(int)4", .name = "Xan Wing Commander 4" },
    .{ .fccs = &.{ c.GST_RIFF_RT21, c.GST_RIFF_rt21 }, .caps = "video/x-indeo, indeoversion=(int)2", .name = "Intel Video 2" },
    .{ .fccs = &.{ c.GST_RIFF_IV31, c.GST_RIFF_IV32, c.GST_RIFF_iv31, c.GST_RIFF_iv32 }, .caps = "video/x-indeo, indeoversion=(int)3", .name = "Intel Video 3" },
    .{ .fccs = &.{ c.GST_RIFF_IV41, c.GST_RIFF_iv41 }, .caps = "video/x-indeo, indeoversion=(int)4", .name = "Intel Video 4" },
    .{ .fccs = &.{ c.GST_RIFF_IV50 }, .caps = "video/x-indeo, indeoversion=(int)5", .name = "Intel Video 5" },
    .{ .fccs = &.{ fcc(.{ 'M', 'S', 'Z', 'H' }) }, .caps = "video/x-mszh", .name = "Lossless MSZH Video" },
    .{ .fccs = &.{ fcc(.{ 'Z', 'L', 'I', 'B' }) }, .caps = "video/x-zlib", .name = "Lossless zlib video" },
    .{ .fccs = &.{ fcc(.{ 'C', 'L', 'J', 'R' }), fcc(.{ 'c', 'l', 'j', 'r' }) }, .caps = "video/x-cirrus-logic-accupak", .name = "Cirrus Logipak AccuPak" },
    .{ .fccs = &.{ c.GST_RIFF_CYUV, c.GST_RIFF_cyuv }, .caps = "video/x-compressed-yuv", .name = "CYUV Lossless" },
    .{ .fccs = &.{ fcc(.{ 'D', 'U', 'C', 'K' }), fcc(.{ 'P', 'V', 'E', 'Z' }) }, .caps = "video/x-truemotion, trueversion=(int)1", .name = "Duck Truemotion1" },
    .{ .fccs = &.{ fcc(.{ 'T', 'M', '2', '0' }) }, .caps = "video/x-truemotion, trueversion=(int)2", .name = "TrueMotion 2.0" },
    .{ .fccs = &.{ fcc(.{ 'V', 'P', '3', '0' }), fcc(.{ 'v', 'p', '3', '0' }), fcc(.{ 'V', 'P', '3', '1' }), fcc(.{ 'v', 'p', '3', '1' }), fcc(.{ 'V', 'P', '3', ' ' }) }, .caps = "video/x-vp3", .name = "VP3" },
    .{ .fccs = &.{ c.GST_RIFF_ULTI, c.GST_RIFF_ulti }, .caps = "video/x-ultimotion", .name = "IBM UltiMotion" },
    .{ .fccs = &.{ fcc(.{ 'T', 'S', 'C', '2' }), fcc(.{ 't', 's', 'c', '2' }) }, .caps = "video/x-tscc, tsccversion=(int)2", .name = "TechSmith Screen Capture 2" },
    .{ .fccs = &.{ fcc(.{ 'V', 'C', 'R', '1' }) }, .caps = "video/x-ati-vcr, vcrversion=(int)1", .name = "ATI VCR 1" },
    .{ .fccs = &.{ fcc(.{ 'V', 'C', 'R', '2' }) }, .caps = "video/x-ati-vcr, vcrversion=(int)2", .name = "ATI VCR 2" },
    .{ .fccs = &.{ fcc(.{ 'A', 'S', 'V', '1' }) }, .caps = "video/x-asus, asusversion=(int)1", .name = "Asus Video 1" },
    .{ .fccs = &.{ fcc(.{ 'A', 'S', 'V', '2' }) }, .caps = "video/x-asus, asusversion=(int)2", .name = "Asus Video 2" },
    .{ .fccs = &.{ fcc(.{ 'M', 'P', 'N', 'G' }), fcc(.{ 'm', 'p', 'n', 'g' }), fcc(.{ 'P', 'N', 'G', ' ' }), fcc(.{ 'p', 'n', 'g', ' ' }) }, .caps = "image/png", .name = "PNG image" },
    .{ .fccs = &.{ fcc(.{ 'F', 'L', 'V', '1' }) }, .caps = "video/x-flash-video, flvversion=(int)1", .name = "Flash Video 1" },
    .{ .fccs = &.{ fcc(.{ 'd', 'r', 'a', 'c' }) }, .caps = "video/x-dirac", .name = "Dirac" },
    .{ .fccs = &.{ c.GST_RIFF_rpza, c.GST_RIFF_azpr, fcc(.{ 'R', 'P', 'Z', 'A' }) }, .caps = "video/x-apple-video", .name = "Apple Video (RPZA)" },
    .{ .fccs = &.{ fcc(.{ 'F', 'F', 'V', '1' }) }, .caps = "video/x-ffv, ffvversion=(int)1", .name = "FFmpeg lossless video codec" },
    .{ .fccs = &.{ fcc(.{ 'K', 'M', 'V', 'C' }) }, .caps = "video/x-kmvc", .name = "Karl Morton's video codec" },
    .{ .fccs = &.{ fcc(.{ 'v', 'p', '5', '0' }), fcc(.{ 'V', 'P', '5', '0' }) }, .caps = "video/x-vp5", .name = "On2 VP5" },
    .{ .fccs = &.{ fcc(.{ 'v', 'p', '6', '0' }), fcc(.{ 'V', 'P', '6', '0' }), fcc(.{ 'v', 'p', '6', '1' }), fcc(.{ 'V', 'P', '6', '1' }), fcc(.{ 'V', 'p', '6', '2' }), fcc(.{ 'V', 'P', '6', '2' }) }, .caps = "video/x-vp6", .name = "On2 VP6" },
    .{ .fccs = &.{ fcc(.{ 'V', 'P', '6', 'F' }), fcc(.{ 'v', 'p', '6', 'f' }), fcc(.{ 'F', 'L', 'V', '4' }) }, .caps = "video/x-vp6-flash", .name = "On2 VP6" },
    .{ .fccs = &.{ fcc(.{ 'v', 'p', '7', '0' }), fcc(.{ 'V', 'P', '7', '0' }) }, .caps = "video/x-vp7", .name = "On2 VP7" },
    .{ .fccs = &.{ fcc(.{ 'V', 'P', '8', '0' }) }, .caps = "video/x-vp8", .name = "On2 VP8" },
    .{ .fccs = &.{ fcc(.{ 'L', 'M', '2', '0' }) }, .caps = "video/x-mimic", .name = "Mimic webcam" },
    .{ .fccs = &.{ fcc(.{ 'T', 'H', 'E', 'O' }), fcc(.{ 't', 'h', 'e', 'o' }) }, .caps = "video/x-theora", .name = "Theora video codec" },
    .{ .fccs = &.{ fcc(.{ 'F', 'P', 'S', '1' }) }, .caps = "video/x-fraps", .name = "Fraps video" },
    .{ .fccs = &.{ fcc(.{ 'D', 'X', 'S', 'B' }), fcc(.{ 'D', 'X', 'S', 'A' }) }, .caps = "subpicture/x-xsub", .name = "XSUB subpicture stream" },
    .{ .fccs = &.{ fcc(.{ 'L', 'A', 'G', 'S' }) }, .caps = "video/x-lagarith", .name = "Lagarith lossless video codec" },
    .{ .fccs = &.{ fcc(.{ 'M', '1', '0', '1' }), fcc(.{ 'M', '1', '0', '2' }) }, .caps = "video/x-m101", .name = "Matrox uncompressed SD video codec" },

};

fn setName(out: [*c][*c]u8, v: [*c]u8) void {
    if (out != null) out.* = v else c.g_free(v);
}

fn bppCaps(media: [*:0]const u8, strf: [*c]c.gst_riff_strf_vids, field: [*:0]const u8) [*c]c.GstCaps {
    const caps = c.gst_caps_new_empty_simple(media);
    if (strf != null) c.gst_caps_set_simple(caps, field, c.G_TYPE_INT, @as(c.gint, strf[0].bit_cnt), N);
    return caps;
}

fn depthCaps(media: [*:0]const u8, strf: [*c]c.gst_riff_strf_vids) [*c]c.GstCaps {
    if (strf == null) return c.gst_caps_new_empty_simple(media);
    const depth: c.gint = if (strf[0].bit_cnt != 0) strf[0].bit_cnt else 24;
    return c.gst_caps_new_simple(media, "depth", c.G_TYPE_INT, depth, N);
}

fn specialVideo(codec: u32, strf: [*c]c.gst_riff_strf_vids, strf_data: *[*c]c.GstBuffer, palette: *[*c]c.GstBuffer, name: [*c][*c]u8, ok: *bool) [*c]c.GstCaps {
    ok.* = true;
    switch (codec) {
        c.GST_RIFF_DIB, c.GST_RIFF_rgb, c.GST_RIFF_RGB, c.GST_RIFF_RAW => {
            const bpp: c.gint = if (strf != null and strf[0].bit_cnt != 0) strf[0].bit_cnt else 8;
            var caps: [*c]c.GstCaps = null;
            if (strf != null) {
                const fmt: [*:0]const u8 = switch (bpp) {
                    8 => "RGB8P",
                    24 => "BGR",
                    32 => "BGRx",
                    else => {
                        ok.* = false;
                        return null;
                    },
                };
                caps = c.gst_caps_new_simple("video/x-raw", "format", c.G_TYPE_STRING, fmt, N);
            } else caps = c.gst_caps_from_string("video/x-raw, format = (string) { RGB8P, BGR, BGRx }");
            palette.* = strf_data.*;
            strf_data.* = null;
            if (name != null) name.* = if (bpp == 8) c.g_strdup_printf("Palettized %d-bit RGB", bpp) else c.g_strdup_printf("%d-bit RGB", bpp);
            return caps;
        },
        fcc("HFYU".*) => {
            setName(name, c.g_strdup("Huffman Lossless Codec"));
            return bppCaps("video/x-huffyuv", strf, "bpp");
        },
        fcc("FFVH".*) => {
            setName(name, c.g_strdup("FFmpeg Huffman YUV variant"));
            return bppCaps("video/x-ffvhuff", strf, "bpp");
        },
        c.GST_RIFF_FCCH_MSVC, c.GST_RIFF_FCCH_msvc, c.GST_RIFF_CRAM, c.GST_RIFF_cram, c.GST_RIFF_WHAM, c.GST_RIFF_wham => {
            const caps = c.gst_caps_new_simple("video/x-msvideocodec", "msvideoversion", c.G_TYPE_INT, @as(c.gint, 1), N);
            if (strf != null) c.gst_caps_set_simple(caps, "bpp", c.G_TYPE_INT, @as(c.gint, strf[0].bit_cnt), N);
            setName(name, c.g_strdup("MS video v1"));
            palette.* = strf_data.*;
            strf_data.* = null;
            return caps;
        },
        c.GST_RIFF_FCCH_RLE, fcc("mrle".*), fcc(.{ 1, 0, 0, 0 }), fcc(.{ 2, 0, 0, 0 }) => {
            const caps = c.gst_caps_new_simple("video/x-rle", "layout", c.G_TYPE_STRING, "microsoft", N);
            palette.* = strf_data.*;
            strf_data.* = null;
            if (strf != null) {
                c.gst_caps_set_simple(caps, "depth", c.G_TYPE_INT, @as(c.gint, strf[0].bit_cnt), N);
            } else c.gst_caps_set_simple(caps, "depth", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, 64), N);
            setName(name, c.g_strdup("Microsoft RLE"));
            return caps;
        },
        fcc("TSCC".*), fcc("tscc".*) => {
            setName(name, c.g_strdup("TechSmith Camtasia"));
            return depthCaps("video/x-camtasia", strf);
        },
        fcc("CSCD".*) => {
            setName(name, c.g_strdup("Camstudio"));
            return depthCaps("video/x-camstudio", strf);
        },
        fcc("VMnc".*) => {
            const caps = c.gst_caps_new_simple("video/x-vmnc", "version", c.G_TYPE_INT, @as(c.gint, 1), N);
            if (strf != null and strf[0].bit_cnt != 0) c.gst_caps_set_simple(caps, "bpp", c.G_TYPE_INT, @as(c.gint, strf[0].bit_cnt), N);
            setName(name, c.g_strdup("VMWare NC Video"));
            return caps;
        },
        else => {
            ok.* = false;
            return null;
        },
    }
}

fn lookupVideo(codec: u32) ?*const Video {
    for (&videos) |*v| for (v.fccs) |f| if (f == codec) return v;
    return null;
}

pub export fn gst_riff_create_video_caps(codec: c_uint, strh: [*c]c.gst_riff_strh, strf: [*c]c.gst_riff_strf_vids, strf_data_in: [*c]c.GstBuffer, strd_data: [*c]c.GstBuffer, name: [*c][*c]u8) [*c]c.GstCaps {
    var strf_data = strf_data_in;
    var palette: [*c]c.GstBuffer = null;
    var ok = false;
    var caps = specialVideo(codec, strf, &strf_data, &palette, name, &ok);
    if (!ok) {
        if (caps != null) c.gst_caps_unref(caps);
        const v = lookupVideo(codec) orelse return null;
        caps = c.gst_caps_from_string(v.caps);
        setName(name, c.g_strdup(v.name));
    }
    if (caps == null) return null;
    if (strh != null) {
        c.gst_caps_set_simple(caps, "framerate", c.gst_fraction_get_type(), @as(c.gint, @bitCast(strh[0].rate)), @as(c.gint, @bitCast(strh[0].scale)), N);
    } else c.gst_caps_set_simple(caps, "framerate", c.gst_fraction_range_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(c.gint, MAXINT), @as(c.gint, 1), N);
    if (strf != null) {
        const h: c.gint = @bitCast(strf[0].height);
        c.gst_caps_set_simple(caps, "width", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].width)), "height", c.G_TYPE_INT, if (h < 0) -%h else h, N);
    } else c.gst_caps_set_simple(caps, "width", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXINT), "height", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXINT), N);
    if (strf_data != null or strd_data != null) c.gst_caps_set_simple(caps, "codec_data", c.gst_buffer_get_type(), if (strf_data != null) strf_data else strd_data, N);
    if (palette != null) {
        const colors: usize = if (strf != null) strf[0].num_colors else 256;
        const size = c.gst_buffer_get_size(palette);
        const expected = std.math.mul(usize, colors, 4) catch std.math.maxInt(usize);
        if (expected != std.math.maxInt(usize) and size >= expected) {
            const pdata: [*]u8 = @ptrCast(c.g_malloc0(@max(size, 256 * 4)));
            _ = c.gst_buffer_extract(palette, 0, pdata, size);
            const copy = c.gst_buffer_new_wrapped(pdata, size);
            c.gst_caps_set_simple(caps, "palette_data", c.gst_buffer_get_type(), copy, N);
            c.gst_buffer_unref(copy);
        }
    }
    return caps;
}

const layout = [_]struct { mask: u32, pos: c.GstAudioChannelPosition }{
    .{ .mask = 0x00001, .pos = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT },
    .{ .mask = 0x00002, .pos = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT },
    .{ .mask = 0x00004, .pos = c.GST_AUDIO_CHANNEL_POSITION_FRONT_CENTER },
    .{ .mask = 0x00008, .pos = c.GST_AUDIO_CHANNEL_POSITION_LFE1 },
    .{ .mask = 0x00010, .pos = c.GST_AUDIO_CHANNEL_POSITION_REAR_LEFT },
    .{ .mask = 0x00020, .pos = c.GST_AUDIO_CHANNEL_POSITION_REAR_RIGHT },
    .{ .mask = 0x00040, .pos = c.GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER },
    .{ .mask = 0x00080, .pos = c.GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER },
    .{ .mask = 0x00100, .pos = c.GST_AUDIO_CHANNEL_POSITION_REAR_CENTER },
    .{ .mask = 0x00200, .pos = c.GST_AUDIO_CHANNEL_POSITION_SIDE_LEFT },
    .{ .mask = 0x00400, .pos = c.GST_AUDIO_CHANNEL_POSITION_SIDE_RIGHT },
    .{ .mask = 0x00800, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_CENTER },
    .{ .mask = 0x01000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_LEFT },
    .{ .mask = 0x02000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_CENTER },
    .{ .mask = 0x04000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_RIGHT },
    .{ .mask = 0x08000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_REAR_LEFT },
    .{ .mask = 0x10000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_REAR_CENTER },
    .{ .mask = 0x20000, .pos = c.GST_AUDIO_CHANNEL_POSITION_TOP_REAR_RIGHT },
};

fn extMask(caps: [*c]c.GstCaps, n: c.gint, bits: u32, reorder: [*c]c.gint) bool {
    if (n < 1) return false;
    const cnt: usize = @intCast(n);
    const from: [*]c.GstAudioChannelPosition = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstAudioChannelPosition) * cnt)));
    const to: [*]c.GstAudioChannelPosition = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstAudioChannelPosition) * cnt)));
    defer c.g_free(from);
    defer c.g_free(to);
    var mask: u64 = 0;
    var p: usize = 0;
    for (layout) |l| {
        if (bits & l.mask == 0) continue;
        if (p >= cnt) {
            mask = 0;
            break;
        }
        mask |= @as(u64, 1) << @intCast(l.pos);
        from[p] = l.pos;
        p += 1;
    }
    if (mask > 0 and reorder != null) {
        while (p < cnt) : (p += 1) from[p] = c.GST_AUDIO_CHANNEL_POSITION_INVALID;
        @memcpy(to[0..cnt], from[0..cnt]);
        if (c.gst_audio_channel_positions_to_valid_order(to, n) == 0) return false;
        if (c.gst_audio_get_channel_reorder_map(n, from, to, reorder) == 0) return false;
    }
    c.gst_caps_set_simple(caps, "channel-mask", c.gst_bitmask_get_type(), mask, N);
    return true;
}

const default_reorder = [8][8]c.gint{
    .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 0, 0, 0, 0, 0 },
    .{ 0, 1, 2, 3, 0, 0, 0, 0 },
    .{ 0, 1, 3, 4, 2, 0, 0, 0 },
    .{ 0, 1, 4, 5, 2, 3, 0, 0 },
    .{ 0, 1, 4, 5, 2, 3, 6, 0 },
    .{ 0, 1, 4, 5, 2, 3, 6, 7 },
};

fn defaultMask(caps: [*c]c.GstCaps, n: c.gint, reorder: [*c]c.gint) void {
    if (n <= 1) return;
    const mask = c.gst_audio_channel_get_fallback_mask(n);
    if (reorder != null and n <= 8) {
        const k: usize = @intCast(n);
        @memcpy(reorder[0..k], default_reorder[k - 1][0..k]);
    }
    c.gst_caps_set_simple(caps, "channel-mask", c.gst_bitmask_get_type(), mask, N);
}

fn extDefaultMask(n: c.guint) u32 {
    var m: u32 = 0;
    switch (n) {
        11 => m = 0x00400 | 0x00200 | 0x00100 | 0x00080 | 0x00040 | 0x00020 | 0x00010 | 0x00008 | 0x00004 | 0x00002 | 0x00001,
        9 => m = 0x00100 | 0x00080 | 0x00040 | 0x00020 | 0x00010 | 0x00008 | 0x00004 | 0x00002 | 0x00001,
        8 => m = 0x00080 | 0x00040 | 0x00020 | 0x00010 | 0x00008 | 0x00004 | 0x00002 | 0x00001,
        6 => m = 0x00020 | 0x00010 | 0x00008 | 0x00004 | 0x00002 | 0x00001,
        4 => m = 0x00008 | 0x00004 | 0x00002 | 0x00001,
        3 => m = 0x00004 | 0x00002 | 0x00001,
        2 => m = 0x00002 | 0x00001,
        else => {},
    }
    return m;
}

fn roundUp8(v: c.gint) c.gint {
    return (v + 7) & ~@as(c.gint, 7);
}

fn intFormat(wd: c.gint) c.GstAudioFormat {
    return c.gst_audio_format_build_integer(@intFromBool(wd != 8), c.G_LITTLE_ENDIAN, wd, wd);
}

fn rawCaps(fmt: [*c]const u8, ch: c.gint) [*c]c.GstCaps {
    return c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, fmt, "layout", c.G_TYPE_STRING, "interleaved", "channels", c.G_TYPE_INT, ch, N);
}

fn fixLaw(strf: [*c]c.gst_riff_strf_auds) void {
    if (strf == null) return;
    const s = &strf[0];
    if (s.bits_per_sample != 8) {
        s.bits_per_sample = 8;
        s.blockalign = @truncate((@as(c.guint, s.bits_per_sample) * s.channels) / 8);
        s.av_bps = s.blockalign *% s.rate;
    }
    if (s.av_bps == 0 or s.blockalign == 0) {
        s.blockalign = @truncate((@as(c.guint, s.bits_per_sample) * s.channels) / 8);
        s.av_bps = s.blockalign *% s.rate;
    }
}

fn fixLawExt(strf: [*c]c.gst_riff_strf_auds) void {
    if (strf == null) return;
    const s = &strf[0];
    if (s.bits_per_sample != 8) {
        s.bits_per_sample = 8;
        s.av_bps = 8;
        s.blockalign = @truncate(s.av_bps *% s.channels);
    }
    if (s.av_bps == 0 or s.blockalign == 0) {
        s.av_bps = s.bits_per_sample;
        s.blockalign = @truncate(s.av_bps *% s.channels);
    }
}

fn adpcmRate(strf: [*c]c.gst_riff_strf_auds, header: c.guint, mul: c.gint, add: c.gint) void {
    if (strf == null) return;
    const s = &strf[0];
    s.av_bps = 0;
    if (s.channels != 0 and s.rate != 0 and s.blockalign != 0 and (s.blockalign / s.channels) >= header) {
        const spb: c.gint = (@as(c.gint, s.blockalign / s.channels) - @as(c.gint, @intCast(header))) * mul + add;
        s.av_bps = @truncate(c.gst_util_uint64_scale_int(s.rate, s.blockalign, spb));
    }
}


pub export fn gst_riff_create_audio_caps(codec: c_ushort, strh: [*c]c.gst_riff_strh, strf: [*c]c.gst_riff_strf_auds, strf_data: [*c]c.GstBuffer, strd_data: [*c]c.GstBuffer, name: [*c][*c]u8, reorder: [*c]c.gint) [*c]c.GstCaps {
    var block_align = false;
    var rate_chan = true;
    var caps: [*c]c.GstCaps = null;
    if (reorder != null) @memset(reorder[0..18], -1);
    switch (@as(c_int, codec)) {
        c.GST_RIFF_WAVE_FORMAT_PCM => {
            if (strf != null) {
                const s = &strf[0];
                const ba: c.gint = s.blockalign;
                const ch: c.gint = s.channels;
                var wd: c.gint = 0;
                if (ba > 4 * ch) {
                    wd = roundUp8(s.bits_per_sample);
                } else if (ba != 0) {
                    wd = @divTrunc(ba * 8, ch);
                } else wd = roundUp8(s.bits_per_sample);
                if (s.bits_per_sample > 32) s.bits_per_sample = @intCast(wd);
                const fmt = intFormat(wd);
                if (fmt == c.GST_AUDIO_FORMAT_UNKNOWN) return null;
                caps = rawCaps(c.gst_audio_format_to_string(fmt), ch);
                if (ch <= 8) defaultMask(caps, ch, reorder);
            } else caps = c.gst_caps_from_string("audio/x-raw, format = (string) { S8, U8, S16LE, U16LE, S24LE, U24LE, S32LE, U32LE }, layout = (string) interleaved");
            if (name != null and strf != null) name.* = c.g_strdup_printf("Uncompressed %d-bit PCM audio", @as(c_int, strf[0].bits_per_sample));
        },
        c.GST_RIFF_WAVE_FORMAT_ADPCM => {
            adpcmRate(strf, 7, 2, 2);
            caps = c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "microsoft", N);
            setName(name, c.g_strdup("ADPCM audio"));
            block_align = true;
        },
        c.GST_RIFF_WAVE_FORMAT_IEEE_FLOAT => {
            if (strf != null) {
                const ba: c.gint = strf[0].blockalign;
                const ch: c.gint = strf[0].channels;
                if (ba > 0 and ch > 0 and (ba == 8 * ch or ba == 4 * ch)) {
                    const wd = @divTrunc(ba * 8, ch);
                    caps = rawCaps(if (wd == 64) "F64LE" else "F32LE", ch);
                    if (ch <= 8) defaultMask(caps, ch, reorder);
                } else return null;
            } else caps = c.gst_caps_from_string("audio/x-raw, format = (string) { F32LE, F64LE }, layout = (string) interleaved");
            if (name != null and strf != null) name.* = c.g_strdup_printf("Uncompressed %d-bit IEEE float audio", @as(c_int, strf[0].bits_per_sample));
        },
        c.GST_RIFF_WAVE_FORMAT_ALAW => {
            fixLaw(strf);
            caps = c.gst_caps_new_empty_simple("audio/x-alaw");
            setName(name, c.g_strdup("A-law audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_WMS => {
            caps = c.gst_caps_new_empty_simple("audio/x-wms");
            if (strf != null) {
                c.gst_caps_set_simple(caps, "bitrate", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].av_bps *% 8)), "width", c.G_TYPE_INT, @as(c.gint, strf[0].bits_per_sample), "depth", c.G_TYPE_INT, @as(c.gint, strf[0].bits_per_sample), N);
            } else c.gst_caps_set_simple(caps, "bitrate", c.gst_int_range_get_type(), @as(c.gint, 0), @as(c.gint, MAXINT), N);
            setName(name, c.g_strdup("Windows Media Audio Speech"));
            block_align = true;
        },
        c.GST_RIFF_WAVE_FORMAT_MULAW => {
            fixLaw(strf);
            caps = c.gst_caps_new_empty_simple("audio/x-mulaw");
            setName(name, c.g_strdup("Mu-law audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_DVI_ADPCM => {
            adpcmRate(strf, 4, 2, 1);
            caps = c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "dvi", N);
            setName(name, c.g_strdup("DVI ADPCM audio"));
            block_align = true;
        },
        c.GST_RIFF_WAVE_FORMAT_ADPCM_G722 => {
            caps = c.gst_caps_new_empty_simple("audio/G722");
            setName(name, c.g_strdup("G722 audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_ITU_G726_ADPCM => {
            var bitrate: c.gint = 0;
            if (strf != null) {
                const s = &strf[0];
                if (s.av_bps == 2000 or s.av_bps == 3000 or s.av_bps == 4000 or s.av_bps == 5000) {
                    s.blockalign = @truncate(s.av_bps / 1000);
                    bitrate = @intCast(s.av_bps * 8);
                } else if (s.blockalign >= 2 and s.blockalign <= 5) bitrate = @as(c.gint, s.blockalign) * 8000;
            }
            caps = if (bitrate > 0) c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "g726", "bitrate", c.G_TYPE_INT, bitrate, N) else c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "g726", N);
            setName(name, c.g_strdup("G726 ADPCM audio"));
            block_align = true;
        },
        c.GST_RIFF_WAVE_FORMAT_DSP_TRUESPEECH => {
            caps = c.gst_caps_new_empty_simple("audio/x-truespeech");
            setName(name, c.g_strdup("DSP Group TrueSpeech"));
        },
        c.GST_RIFF_WAVE_FORMAT_GSM610, c.GST_RIFF_WAVE_FORMAT_MSN => {
            caps = c.gst_caps_new_empty_simple("audio/ms-gsm");
            setName(name, c.g_strdup("MS GSM audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_MPEGL12 => {
            caps = c.gst_caps_new_simple("audio/mpeg", "mpegversion", c.G_TYPE_INT, @as(c.gint, 1), "layer", c.G_TYPE_INT, @as(c.gint, 2), N);
            setName(name, c.g_strdup("MPEG-1 layer 2"));
        },
        c.GST_RIFF_WAVE_FORMAT_MPEGL3 => {
            caps = c.gst_caps_new_simple("audio/mpeg", "mpegversion", c.G_TYPE_INT, @as(c.gint, 1), "layer", c.G_TYPE_INT, @as(c.gint, 3), N);
            setName(name, c.g_strdup("MPEG-1 layer 3"));
        },
        c.GST_RIFF_WAVE_FORMAT_AMR_NB => {
            caps = c.gst_caps_new_empty_simple("audio/AMR");
            setName(name, c.g_strdup("AMR Narrow Band (NB)"));
        },
        c.GST_RIFF_WAVE_FORMAT_AMR_WB => {
            caps = c.gst_caps_new_empty_simple("audio/AMR-WB");
            setName(name, c.g_strdup("AMR Wide Band (WB)"));
        },
        c.GST_RIFF_WAVE_FORMAT_VORBIS1, c.GST_RIFF_WAVE_FORMAT_VORBIS2, c.GST_RIFF_WAVE_FORMAT_VORBIS3, c.GST_RIFF_WAVE_FORMAT_VORBIS1PLUS, c.GST_RIFF_WAVE_FORMAT_VORBIS2PLUS, c.GST_RIFF_WAVE_FORMAT_VORBIS3PLUS => {
            caps = c.gst_caps_new_empty_simple("audio/x-vorbis");
            setName(name, c.g_strdup("Vorbis"));
        },
        c.GST_RIFF_WAVE_FORMAT_A52 => {
            caps = c.gst_caps_new_empty_simple("audio/x-ac3");
            setName(name, c.g_strdup("AC-3 audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_DTS => {
            caps = c.gst_caps_new_empty_simple("audio/x-dts");
            setName(name, c.g_strdup("DTS audio"));
            rate_chan = false;
        },
        c.GST_RIFF_WAVE_FORMAT_AAC, c.GST_RIFF_WAVE_FORMAT_AAC_AC, c.GST_RIFF_WAVE_FORMAT_AAC_pm => {
            caps = c.gst_caps_new_simple("audio/mpeg", "mpegversion", c.G_TYPE_INT, @as(c.gint, 4), N);
            setName(name, c.g_strdup("MPEG-4 AAC audio"));
        },
        c.GST_RIFF_WAVE_FORMAT_WMAV1, c.GST_RIFF_WAVE_FORMAT_WMAV2, c.GST_RIFF_WAVE_FORMAT_WMAV3, c.GST_RIFF_WAVE_FORMAT_WMAV3_L => {
            const version: c.gint = @as(c.gint, codec) - c.GST_RIFF_WAVE_FORMAT_WMAV1 + 1;
            block_align = true;
            caps = c.gst_caps_new_simple("audio/x-wma", "wmaversion", c.G_TYPE_INT, version, N);
            setName(name, if (codec == c.GST_RIFF_WAVE_FORMAT_WMAV3_L) c.g_strdup("WMA Lossless") else c.g_strdup_printf("WMA Version %d", version + 6));
            if (strf != null) {
                c.gst_caps_set_simple(caps, "bitrate", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].av_bps *% 8)), "depth", c.G_TYPE_INT, @as(c.gint, strf[0].bits_per_sample), N);
            } else c.gst_caps_set_simple(caps, "bitrate", c.gst_int_range_get_type(), @as(c.gint, 0), @as(c.gint, MAXINT), N);
        },
        c.GST_RIFF_WAVE_FORMAT_SONY_ATRAC3 => {
            caps = c.gst_caps_new_empty_simple("audio/x-vnd.sony.atrac3");
            setName(name, c.g_strdup("Sony ATRAC3"));
        },
        c.GST_RIFF_WAVE_FORMAT_SIREN => {
            caps = c.gst_caps_new_empty_simple("audio/x-siren");
            setName(name, c.g_strdup("Siren7"));
            rate_chan = false;
        },
        c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_DK4 => {
            caps = c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "dk4", N);
            setName(name, c.g_strdup("IMA/DK4 ADPCM"));
        },
        c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_DK3 => {
            caps = c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "dk3", N);
            setName(name, c.g_strdup("IMA/DK3 ADPCM"));
        },
        c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_WAV => {
            caps = c.gst_caps_new_simple("audio/x-adpcm", "layout", c.G_TYPE_STRING, "dvi", N);
            setName(name, c.g_strdup("IMA/WAV ADPCM"));
        },
        c.GST_RIFF_WAVE_FORMAT_EXTENSIBLE => {
            if (strf_data == null) return null;
            if (c.gst_buffer_get_size(strf_data) < 22) return null;
            var map: c.GstMapInfo = undefined;
            _ = c.gst_buffer_map(strf_data, &map, c.GST_MAP_READ);
            const d: [*]const u8 = map.data;
            var mask = std.mem.readInt(u32, d[2..6], .little);
            const g = [4]u32{ std.mem.readInt(u32, d[6..10], .little), std.mem.readInt(u32, d[10..14], .little), std.mem.readInt(u32, d[14..18], .little), std.mem.readInt(u32, d[18..22], .little) };
            c.gst_buffer_unmap(strf_data, &map);
            if (g[1] == 0x00100000 and g[2] == 0xaa000080 and g[3] == 0x719b3800) {
                if (g[0] == 1) {
                    if (strf != null and strf[0].blockalign != 0 and strf[0].channels != 0 and strf[0].rate != 0) {
                        const wd = @divTrunc(@as(c.gint, strf[0].blockalign) * 8, @as(c.gint, strf[0].channels));
                        caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, c.gst_audio_format_to_string(intFormat(wd)), "layout", c.G_TYPE_STRING, "interleaved", "channels", c.G_TYPE_INT, @as(c.gint, strf[0].channels), "rate", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].rate)), N);
                        if (name != null) name.* = c.g_strdup_printf("Uncompressed %d-bit PCM audio", @as(c_int, strf[0].bits_per_sample));
                    }
                } else if (g[0] == 3) {
                    if (strf != null and strf[0].blockalign != 0 and strf[0].channels != 0 and strf[0].rate != 0) {
                        const wd = @divTrunc(@as(c.gint, strf[0].blockalign) * 8, @as(c.gint, strf[0].channels));
                        caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, @as([*:0]const u8, if (wd == 32) "F32LE" else "F64LE"), "layout", c.G_TYPE_STRING, "interleaved", "channels", c.G_TYPE_INT, @as(c.gint, strf[0].channels), "rate", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].rate)), N);
                        if (name != null) name.* = c.g_strdup_printf("Uncompressed %d-bit IEEE float audio", @as(c_int, strf[0].bits_per_sample));
                    }
                } else if (g[0] == 6) {
                    fixLawExt(strf);
                    caps = c.gst_caps_new_empty_simple("audio/x-alaw");
                    setName(name, c.g_strdup("A-law audio"));
                } else if (g[0] == 7) {
                    fixLawExt(strf);
                    caps = c.gst_caps_new_empty_simple("audio/x-mulaw");
                    setName(name, c.g_strdup("Mu-law audio"));
                } else if (g[0] == 0x92) {
                    caps = c.gst_caps_new_empty_simple("audio/x-ac3");
                    setName(name, c.g_strdup("wavext AC-3 SPDIF audio"));
                } else if (g[0] & 0xffff == c.GST_RIFF_WAVE_FORMAT_EXTENSIBLE) {} else {
                    caps = gst_riff_create_audio_caps(@truncate(g[0]), strh, strf, strf_data, strd_data, name, reorder);
                    if (caps != null) {
                        if (name != null) {
                            const tmp = name.*;
                            name.* = c.g_strjoin("wavext ", tmp, @as([*c]const u8, null));
                            c.g_free(tmp);
                        }
                        return caps;
                    }
                }
            } else if (g[0] == 0x6ba47966 and g[1] == 0x41783f83 and g[2] == 0xf0006596 and g[3] == 0xe59262bf) {
                caps = c.gst_caps_new_empty_simple("application/x-ogg-avi");
                setName(name, c.g_strdup("Ogg-AVI"));
            }
            if (caps == null) return null;
            if (strf != null) {
                if (mask == 0 and strf[0].channels > 1) mask = extDefaultMask(strf[0].channels);
                if ((mask != 0 or strf[0].channels > 1) and !extMask(caps, strf[0].channels, mask, reorder)) {
                    c.gst_caps_unref(caps);
                    caps = null;
                }
                rate_chan = false;
            }
        },
        c.GST_RIFF_WAVE_FORMAT_VOXWARE_AC8, c.GST_RIFF_WAVE_FORMAT_VOXWARE_AC10, c.GST_RIFF_WAVE_FORMAT_VOXWARE_AC16, c.GST_RIFF_WAVE_FORMAT_VOXWARE_AC20, c.GST_RIFF_WAVE_FORMAT_VOXWARE_METAVOICE, c.GST_RIFF_WAVE_FORMAT_VOXWARE_METASOUND, c.GST_RIFF_WAVE_FORMAT_VOXWARE_RT29HW, c.GST_RIFF_WAVE_FORMAT_VOXWARE_VR12, c.GST_RIFF_WAVE_FORMAT_VOXWARE_VR18, c.GST_RIFF_WAVE_FORMAT_VOXWARE_TQ40, c.GST_RIFF_WAVE_FORMAT_VOXWARE_TQ60 => {
            caps = c.gst_caps_new_simple("audio/x-voxware", "voxwaretype", c.G_TYPE_INT, @as(c.gint, codec), N);
            setName(name, c.g_strdup("Voxware"));
        },
        else => return null,
    }
    if (strf != null) {
        if (rate_chan) c.gst_caps_set_simple(caps, "rate", c.G_TYPE_INT, @as(c.gint, @bitCast(strf[0].rate)), "channels", c.G_TYPE_INT, @as(c.gint, strf[0].channels), N);
        if (block_align) c.gst_caps_set_simple(caps, "block_align", c.G_TYPE_INT, @as(c.gint, strf[0].blockalign), N);
    } else if (block_align) c.gst_caps_set_simple(caps, "block_align", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, MAXINT), N);
    if (strf_data != null or strd_data != null) c.gst_caps_set_simple(caps, "codec_data", c.gst_buffer_get_type(), if (strf_data != null) strf_data else strd_data, N);
    return caps;
}

pub export fn gst_riff_create_iavs_caps(codec: c_uint, _: [*c]c.gst_riff_strh, _: [*c]c.gst_riff_strf_iavs, _: [*c]c.GstBuffer, _: [*c]c.GstBuffer, name: [*c][*c]u8) [*c]c.GstCaps {
    if (codec != fcc("DVSD".*) and codec != fcc("dvsd".*)) return null;
    setName(name, c.g_strdup("Generic DV"));
    return c.gst_caps_new_simple("video/x-dv", "systemstream", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
}

const video_tags = [_][4]u8{ "3IV1".*, "ASV1".*, "ASV2".*, "CFHD".*, "CLJR".*, "CSCD".*, "CYUV".*, "DIB ".*, "DIV3".*, "DIVX".*, "DUCK".*, "DVSD".*, "DV50".*, "DX50".*, "M4CC".*, "FLV1".*, "FLV4".*, "H263".*, "VX1K".*, "H264".*, "H265".*, "HFYU".*, "I263".*, "I420".*, "IV32".*, "IV41".*, "IV50".*, "L263".*, "L264".*, "M263".*, "M4S2".*, "MJPG".*, "MP42".*, "MP43".*, "MPEG".*, "MPG2".*, "MPG4".*, "MSZH".*, "PNG ".*, "RLE ".*, "RT21".*, "SP53".*, "TM20".*, "TSCC".*, "ULTI".*, "UYVY".*, "VCR1".*, "VCR2".*, "VDOW".*, "VIVO".*, "VMnc".*, "VP3 ".*, "VSSH".*, "WMV1".*, "WMV2".*, "WMV3".*, "XVID".*, "Xxan".*, "YUY2".*, "YVU9".*, "ZLIB".*, "cvid".*, "h264".*, "msvc".*, "x263".*, "drac".*, "FFV1".*, "KMVC".*, "VP50".*, "VP60".*, "VP6F".*, "VP70".*, "VP80".*, "LM20".*, "RPZA".*, "THEO".*, "FPS1".*, "AASC".*, "YV12".*, "LOCO".*, "ZMBV".*, "v210".*, "r210".* };

pub export fn gst_riff_create_video_template_caps() [*c]c.GstCaps {
    const caps = c.gst_caps_new_empty();
    for (video_tags) |t| {
        const one = gst_riff_create_video_caps(fcc(t), null, null, null, null, null);
        if (one != null) c.gst_caps_append(caps, one);
    }
    return caps;
}

const audio_tags = [_]c_int{ c.GST_RIFF_WAVE_FORMAT_GSM610, c.GST_RIFF_WAVE_FORMAT_MPEGL3, c.GST_RIFF_WAVE_FORMAT_MPEGL12, c.GST_RIFF_WAVE_FORMAT_PCM, c.GST_RIFF_WAVE_FORMAT_VORBIS1, c.GST_RIFF_WAVE_FORMAT_A52, c.GST_RIFF_WAVE_FORMAT_DTS, c.GST_RIFF_WAVE_FORMAT_AAC, c.GST_RIFF_WAVE_FORMAT_ALAW, c.GST_RIFF_WAVE_FORMAT_MULAW, c.GST_RIFF_WAVE_FORMAT_WMS, c.GST_RIFF_WAVE_FORMAT_ADPCM, c.GST_RIFF_WAVE_FORMAT_DVI_ADPCM, c.GST_RIFF_WAVE_FORMAT_DSP_TRUESPEECH, c.GST_RIFF_WAVE_FORMAT_WMAV1, c.GST_RIFF_WAVE_FORMAT_WMAV2, c.GST_RIFF_WAVE_FORMAT_WMAV3, c.GST_RIFF_WAVE_FORMAT_SONY_ATRAC3, c.GST_RIFF_WAVE_FORMAT_IEEE_FLOAT, c.GST_RIFF_WAVE_FORMAT_VOXWARE_METASOUND, c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_DK4, c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_DK3, c.GST_RIFF_WAVE_FORMAT_ADPCM_IMA_WAV, c.GST_RIFF_WAVE_FORMAT_AMR_NB, c.GST_RIFF_WAVE_FORMAT_AMR_WB, c.GST_RIFF_WAVE_FORMAT_SIREN };

pub export fn gst_riff_create_audio_template_caps() [*c]c.GstCaps {
    const caps = c.gst_caps_new_empty();
    for (audio_tags) |t| {
        const one = gst_riff_create_audio_caps(@intCast(t), null, null, null, null, null, null);
        if (one != null) c.gst_caps_append(caps, one);
    }
    c.gst_caps_append(caps, c.gst_caps_new_empty_simple("application/x-ogg-avi"));
    return caps;
}

pub export fn gst_riff_create_iavs_template_caps() [*c]c.GstCaps {
    const caps = c.gst_caps_new_empty();
    const one = gst_riff_create_iavs_caps(fcc("DVSD".*), null, null, null, null, null);
    if (one != null) c.gst_caps_append(caps, one);
    return caps;
}
