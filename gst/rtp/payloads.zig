const std = @import("std");
const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

const Info = c.GstRTPPayloadInfo;

fn row(pt: u8, media: [*:0]const u8, enc: [*:0]const u8, rate: c.guint, params: ?[*:0]const u8, br: c.guint) Info {
    return .{ .payload_type = pt, .media = media, .encoding_name = enc, .clock_rate = rate, .encoding_parameters = params, .bitrate = br, ._gst_reserved = .{ null, null, null, null } };
}

const table = [_]Info{
    row(0, "audio", "PCMU", 8000, "1", 64000),
    row(3, "audio", "GSM", 8000, "1", 0),
    row(4, "audio", "G723", 8000, "1", 0),
    row(5, "audio", "DVI4", 8000, "1", 32000),
    row(6, "audio", "DVI4", 16000, "1", 64000),
    row(7, "audio", "LPC", 8000, "1", 0),
    row(8, "audio", "PCMA", 8000, "1", 64000),
    row(9, "audio", "G722", 8000, "1", 64000),
    row(10, "audio", "L16", 44100, "2", 1411200),
    row(11, "audio", "L16", 44100, "1", 705600),
    row(12, "audio", "QCELP", 8000, "1", 0),
    row(13, "audio", "CN", 8000, "1", 0),
    row(14, "audio", "MPA", 90000, null, 0),
    row(15, "audio", "G728", 8000, "1", 0),
    row(16, "audio", "DVI4", 11025, "1", 44100),
    row(17, "audio", "DVI4", 22050, "1", 88200),
    row(18, "audio", "G729", 8000, "1", 0),
    row(25, "video", "CelB", 90000, null, 0),
    row(26, "video", "JPEG", 90000, null, 0),
    row(28, "video", "nv", 90000, null, 0),
    row(31, "video", "H261", 90000, null, 0),
    row(32, "video", "MPV", 90000, null, 0),
    row(33, "video", "MP2T", 90000, null, 0),
    row(34, "video", "H263", 90000, null, 0),
    row(255, "application", "parityfec", 0, null, 0),
    row(255, "application", "rtx", 0, null, 0),
    row(255, "audio", "AMR", 8000, null, 0),
    row(255, "audio", "AMR-WB", 16000, null, 0),
    row(255, "audio", "DAT12", 0, null, 0),
    row(255, "audio", "dsr-es201108", 0, null, 0),
    row(255, "audio", "EVRC", 8000, "1", 0),
    row(255, "audio", "EVRC0", 8000, "1", 0),
    row(255, "audio", "EVRC1", 8000, "1", 0),
    row(255, "audio", "EVRCB", 8000, "1", 0),
    row(255, "audio", "EVRCB0", 8000, "1", 0),
    row(255, "audio", "EVRCB1", 8000, "1", 0),
    row(255, "audio", "G7221", 16000, "1", 0),
    row(255, "audio", "G726-16", 8000, "1", 0),
    row(255, "audio", "G726-24", 8000, "1", 0),
    row(255, "audio", "G726-32", 8000, "1", 0),
    row(255, "audio", "G726-40", 8000, "1", 0),
    row(255, "audio", "G729D", 8000, "1", 0),
    row(255, "audio", "G729E", 8000, "1", 0),
    row(255, "audio", "GSM-EFR", 8000, "1", 0),
    row(255, "audio", "L8", 0, null, 0),
    row(255, "audio", "RED", 0, null, 0),
    row(255, "audio", "rtx", 0, null, 0),
    row(255, "audio", "VDVI", 0, "1", 0),
    row(255, "audio", "L20", 0, null, 0),
    row(255, "audio", "L24", 0, null, 0),
    row(255, "audio", "MP4A-LATM", 0, null, 0),
    row(255, "audio", "mpa-robust", 90000, null, 0),
    row(255, "audio", "parityfec", 0, null, 0),
    row(255, "audio", "SMV", 8000, "1", 0),
    row(255, "audio", "SMV0", 8000, "1", 0),
    row(255, "audio", "t140c", 0, null, 0),
    row(255, "audio", "t38", 0, null, 0),
    row(255, "audio", "telephone-event", 0, null, 0),
    row(255, "audio", "tone", 0, null, 0),
    row(255, "audio", "DVI4", 0, null, 0),
    row(255, "audio", "G722", 0, null, 0),
    row(255, "audio", "G723", 0, null, 0),
    row(255, "audio", "G728", 0, null, 0),
    row(255, "audio", "G729", 0, null, 0),
    row(255, "audio", "GSM", 0, null, 0),
    row(255, "audio", "L16", 0, null, 0),
    row(255, "audio", "LPC", 0, null, 0),
    row(255, "audio", "PCMA", 0, null, 0),
    row(255, "audio", "PCMU", 0, null, 0),
    row(255, "text", "parityfec", 0, null, 0),
    row(255, "text", "red", 1000, null, 0),
    row(255, "text", "rtx", 0, null, 0),
    row(255, "text", "t140", 1000, null, 0),
    row(255, "video", "BMPEG", 90000, null, 0),
    row(255, "video", "BT656", 90000, null, 0),
    row(255, "video", "DV", 90000, null, 0),
    row(255, "video", "H263-1998", 90000, null, 0),
    row(255, "video", "H263-2000", 90000, null, 0),
    row(255, "video", "MP1S", 90000, null, 0),
    row(255, "video", "MP2P", 90000, null, 0),
    row(255, "video", "MP4V-ES", 90000, null, 0),
    row(255, "video", "parityfec", 0, null, 0),
    row(255, "video", "pointer", 90000, null, 0),
    row(255, "video", "raw", 90000, null, 0),
    row(255, "video", "rtx", 0, null, 0),
    row(255, "video", "SMPTE292M", 0, null, 0),
    row(255, "video", "vc1", 90000, null, 0),
    row(255, "audio", "AC3", 0, null, 0),
    row(255, "audio", "ILBC", 8000, null, 0),
    row(255, "audio", "MPEG4-GENERIC", 0, null, 0),
    row(255, "audio", "SPEEX", 0, null, 0),
    row(255, "audio", "OPUS", 48000, null, 0),
    row(255, "application", "MPEG4-GENERIC", 0, null, 0),
    row(255, "video", "H264", 90000, null, 0),
    row(255, "video", "H265", 90000, null, 0),
    row(255, "video", "H266", 90000, null, 0),
    row(255, "video", "MPEG4-GENERIC", 90000, null, 0),
    row(255, "video", "THEORA", 0, null, 0),
    row(255, "video", "VORBIS", 0, null, 0),
    row(255, "video", "X-SV3V-ES", 90000, null, 0),
    row(255, "video", "X-SORENSON-VIDEO", 90000, null, 0),
    row(255, "video", "VP8", 90000, null, 0),
    row(255, "video", "VP9", 90000, null, 0),
    row(255, "video", "AV1", 90000, null, 0),
    row(255, "video", "x-pn-realvideo", 1000, null, 0),
    row(255, "audio", "x-pn-realaudio", 1000, null, 0),
    row(255, "application", "x-pn-realmedia", 1000, null, 0),
};

pub export fn gst_rtp_payload_info_for_pt(pt: u8) [*c]const Info {
    for (&table) |*i| if (i.payload_type == pt) return i;
    return null;
}

pub export fn gst_rtp_payload_info_for_name(media: [*c]const u8, enc: [*c]const u8) [*c]const Info {
    for (&table) |*i| {
        if (c.strcmp(media, i.media) == 0 and c.g_ascii_strcasecmp(enc, i.encoding_name) == 0) return i;
    }
    return null;
}
