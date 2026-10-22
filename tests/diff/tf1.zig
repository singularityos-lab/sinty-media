const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;

const Blob = struct { name: []const u8, data: []const u8 };

var blobs: std.ArrayList(Blob) = .empty;

fn add(name: []const u8, data: []const u8) void {
    blobs.append(A, .{ .name = name, .data = data }) catch unreachable;
}

const Builder = struct {
    b: std.ArrayList(u8) = .empty,

    fn put(self: *Builder, bytes: []const u8) void {
        self.b.appendSlice(A, bytes) catch unreachable;
    }

    fn byte(self: *Builder, v: u8) void {
        self.b.append(A, v) catch unreachable;
    }

    fn zeros(self: *Builder, n: usize) void {
        self.b.appendNTimes(A, 0, n) catch unreachable;
    }

    fn padTo(self: *Builder, n: usize) void {
        if (self.b.items.len < n) self.zeros(n - self.b.items.len);
    }

    fn done(self: *Builder) []const u8 {
        return self.b.items;
    }
};

fn collect(_: ?*c.GstElement, buf: [*c]c.GstBuffer, _: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const arr: *Builder = @ptrCast(@alignCast(data));
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) return;
    arr.put(@as([*]const u8, @ptrCast(map.data))[0..map.size]);
    c.gst_buffer_unmap(buf, &map);
}

fn encode(name: []const u8, desc: [:0]const u8) void {
    var err: [*c]c.GError = null;
    const full = std.fmt.allocPrintSentinel(A, "{s} ! fakesink name=sink signal-handoffs=true sync=false", .{desc}, 0) catch unreachable;
    const p = c.gst_parse_launch(full.ptr, &err);
    if (p == null) {
        out("encoder {s} unavailable", .{name});
        c.g_clear_error(&err);
        return;
    }
    const b = A.create(Builder) catch unreachable;
    b.* = .{};
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&collect), b, null, 0);
    c.gst_object_unref(sink);
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m != null) c.gst_mini_object_unref(@ptrCast(m));
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
    out("encoder {s} bytes {d}", .{ name, b.b.items.len });
    if (b.b.items.len > 0) add(name, b.done());
}

fn frames(name: []const u8, frame: []const u8, count: usize, lead: []const u8) void {
    var b = Builder{};
    b.put(lead);
    for (0..count) |_| b.put(frame);
    add(name, b.done());
}

fn sized(head: []const u8, size: usize) []const u8 {
    var b = Builder{};
    b.put(head);
    b.padTo(size);
    return b.done();
}

fn synthetic() void {
    add("empty-1", "\x00");
    add("short-3", "abc");
    add("zeros", sized("", 70000));
    var r: u32 = 12345;
    var rnd = Builder{};
    for (0..70000) |_| {
        r = r *% 1103515245 +% 12345;
        rnd.byte(@truncate(r >> 16));
    }
    add("random", rnd.done());
    add("ff", &([_]u8{0xff} ** 4096));
    add("html-doctype", "<!DOCTYPE html>\n<html><head></head><body>hello</body></html>\n");
    add("html-tag", "  <html>\n<body>x</body></html>\n                                  ");
    add("xml-decl", "<?xml version=\"1.0\"?>\n<!-- c -->\n<root a=\"1\">text</root>\n               ");
    add("svg", "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\"></svg>\n");
    add("svg-tag", "<svg width=\"10\" height=\"10\"><rect/></svg>                                                 ");
    add("smil", "<?xml version=\"1.0\"?><smil xmlns=\"x\"><body/></smil>                                  ");
    add("ttml", "<?xml version=\"1.0\"?><tt xmlns=\"http://www.w3.org/ns/ttml\"><body/></tt>            ");
    add("dash", "<?xml version=\"1.0\"?>\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\"></MPD>\n");
    add("mss", "<?xml version=\"1.0\"?><SmoothStreamingMedia MajorVersion=\"2\"></SmoothStreamingMedia>   ");
    add("xges", "<?xml version=\"1.0\"?><ges version=\"0.1\"><project/></ges>                           ");
    add("fcpxml", "<?xml version=\"1.0\"?><fcpxml version=\"1.8\"></fcpxml>                             ");
    add("xmeml", "<?xml version=\"1.0\"?><xmeml version=\"5\"></xmeml>                                  ");
    add("otio", "{\n    \"OTIO_SCHEMA\": \"Timeline.1\",\n    \"name\": \"x\"\n}\n                ");
    add("hls", "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\na.ts\n");
    add("hls-master", "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nlow.m3u8\n            ");
    add("sdp", "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=x\r\nc=IN IP4 1.2.3.4\r\nt=0 0\r\n");
    add("uri", "# comment\nhttp://example.com/a.ogg\nhttp://example.com/b.ogg\n");
    add("utf8", "Il testo semplice è una cosa normale, con accenti àèìòù e niente altro di speciale.\n" ** 4);
    add("utf16le", "\xff\xfeh\x00e\x00l\x00l\x00o\x00 \x00w\x00o\x00r\x00l\x00d\x00");
    add("utf16be", "\xfe\xff\x00h\x00e\x00l\x00l\x00o\x00 \x00w\x00o\x00r\x00l\x00d");
    add("utf32le", "\xff\xfe\x00\x00h\x00\x00\x00i\x00\x00\x00");
    add("ssa", "[Script Info]\nTitle: x\nScriptType: v4.00+\n\n[V4+ Styles]\nFormat: Name\n");
    add("ssa-old", "[Script Info]\nScriptType: v4.00\n[V4 Styles]\n                    ");
    add("webvtt", "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n");
    add("webvtt-bom", "\xef\xbb\xbfWEBVTT\n\n");
    add("mcc", "File Format=MacCaption_MCC V1.0\n\n");
    add("postscript", "%!PS-Adobe-3.0\n%%EOF\n");
    add("multipart", "\r\n--boundary\r\nContent-Type: image/jpeg\r\n\r\nxxxx" ++ " " ** 300);
    add("ar", "!<arch>\nfoo.o/          0           0     0     644     4         `\n");
    var tar = Builder{};
    tar.put("file.txt");
    tar.padTo(257);
    tar.put("ustar  \x00");
    tar.padTo(1024);
    add("tar", tar.done());
    var tar2 = Builder{};
    tar2.padTo(257);
    tar2.put("ustar\x0000");
    tar2.padTo(1024);
    add("tar-posix", tar2.done());
    var mz = Builder{};
    mz.put("MZ\x90\x00\x03\x00\x00\x00\x04\x00");
    mz.padTo(60);
    mz.put("\x80\x00\x00\x00");
    mz.padTo(128);
    mz.put("PE\x00\x00");
    mz.padTo(512);
    add("msdos", mz.done());
    add("ico", sized("\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x20\x00\x68\x04\x00\x00\x16\x00\x00\x00", 1150));
    add("wbmp", sized("\x00\x00\x08\x04", 8));
    add("tiff-le", sized("II*\x00\x08\x00\x00\x00", 64));
    add("tiff-be", sized("MM\x00*\x00\x00\x00\x08", 64));
    add("bmp", sized("BM\x46\x00\x00\x00\x00\x00\x00\x00\x36\x00\x00\x00\x28\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x01\x00\x18\x00", 70));
    add("exr", sized("\x76\x2f\x31\x01\x02\x00\x00\x00", 64));
    add("pnm", sized("P6\n# comment\n16 8\n255\n", 400));
    add("pnm-ascii", sized("P1 4 4\n0 1 0 1\n", 64));
    add("pam", sized("P7\nWIDTH 2\n", 64));
    add("sds", sized("\xf0\x7e\x00\x01", 32));
    add("ircam", sized("\x64\xa3\x01\x00", 32));
    add("aiff", sized("FORM\x00\x00\x10\x00AIFFCOMM", 64));
    add("svx", sized("FORM\x00\x00\x10\x008SVXVHDR", 64));
    add("iff", sized("FORM\x00\x00\x10\x00ILBMBMHD", 64));
    add("iff-dsd", sized("FRM8\x00\x00\x00\x00\x00\x00\x10\x00DSD ", 64));
    var modb = Builder{};
    modb.padTo(1080);
    modb.put("M.K.");
    modb.padTo(2048);
    add("mod", modb.done());
    var s3m = Builder{};
    s3m.put("song");
    s3m.padTo(44);
    s3m.put("SCRM");
    s3m.padTo(256);
    add("s3m", s3m.done());
    add("xm", sized("Extended Module: song name here     \x1a", 128));
    add("it", sized("IMPMsong", 128));
    add("j2b", sized("MUSE\xde\xad\xbe\xef", 64));
    add("okt", sized("OKTASONGCMOD", 64));
    add("med", sized("MMD0", 64));
    add("669", sized("if  ", 64));
    add("stm", sized("song name...........!Scream!\x1a\x02", 64));
    add("vivo", sized("\x00\x10\r\nVersion:Vivo/1.0\r\n", 1024));
    var iso = Builder{};
    iso.zeros(0x8000);
    iso.put("\x01CD001");
    iso.padTo(0x8100);
    add("dvdiso", iso.done());
    add("degas", sized("\x00\x01", 32034));
    add("midi", sized("MThd\x00\x00\x00\x06\x00\x01", 64));
    add("mxmf", sized("XMF_2.00\x00\x00\x00\x02", 64));
    add("flx", sized("\x00\x00\x00\x00\x12\xaf", 256));
    var id3 = Builder{};
    id3.put("some audio data here");
    id3.padTo(512);
    id3.put("TAG");
    id3.padTo(640);
    add("id3v1", id3.done());
    add("id3v2", sized("ID3\x03\x00\x00\x00\x00\x00\x10", 64));
    add("apetag", sized("APETAGEX\xd0\x07", 64));
    add("ape", sized("MAC \x96\x0f", 64));
    add("tta", sized("TTA1", 64));
    add("mpc7", sized("MP+\x07", 64));
    add("mpc8", sized("MPCK", 64));
    add("nuv", sized("NuppelVideo", 64));
    add("paris", sized(" paf", 64));
    add("tap", sized("C64-TAPE-RAW", 64));
    add("brstm", sized("RSTM\xfe\xff\x00\x01", 64));
    add("bfstm", sized("FSTM\xfe\xff\x00\x01", 64));
    add("dsf", sized("DSD \x00\x00\x00\x00\x00\x00\x00\x1c", 64));
    add("dsf-odd", sized("DSD \x00\x00\x00\x00\x00\x00\x00\x20", 64));
    add("ea", sized("SCHl\x28\x00\x00\x00", 64));
    add("cpk", sized("FILM\x00\x00\x00\x20\x00\x00\x00\x00\x00\x00\x00\x00FDSC", 64));
    add("gxf", sized("\x00\x00\x00\x00\x01\xbc\x00\x00\x00\x00\x00\x00\x00\x00\xe1\xe2", 64));
    add("pva", sized("AV\x01\x00\x55", 64));
    add("aa", sized("\x00\x00\x00\x40\x57\x90\x75\x36", 64));
    add("ilbc", sized("#!iLBC30\n", 64));
    add("sbc", ("\x9c\x31\x10\x00" ++ "\x00" ** 32) ** 12);
    add("ogm-video", sized("\x01video\x00\x00\x00", 64));
    add("ogm-audio", sized("\x01audio\x00\x00\x00", 64));
    add("ogm-text", sized("\x01text\x00\x00\x00\x00", 64));
    add("speex-hdr", sized("Speex   1.2" ++ "\x00" ** 21 ++ "\x50\x00\x00\x00\x80\x3e\x00\x00\x01\x00\x00\x00", 80));
    add("celt-hdr", sized("CELT    ", 64));
    add("fishead", sized("fishead\x00\x03\x00\x00\x00", 64));
    add("cmml", sized("CMML\x00\x00\x00\x00\x02\x00", 64));
    add("vorbis-hdr", sized("\x01vorbis\x00\x00\x00\x00\x02\x44\xac\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xb8\x01", 64));
    add("theora-hdr", sized("\x80theora\x03\x02\x01", 64));
    add("kate", sized("\x80kate\x00\x00\x00" ++ "\x00" ** 40 ++ "subtitles", 64));
    add("kate-other", sized("\x80kate\x00\x00\x00" ++ "\x00" ** 40 ++ "lyrics", 64));
    add("mmsh", sized("\x24\x48\x40\x00\x00\x00\x00\x00\x00\x00\x00\x00\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c", 64));
    add("dirac", sized("BBCD\x00", 64));
    add("itc", sized("\x00\x00\x01\x1citch\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x02\x00\x00\x00\x00artw", 600));
    add("y4m", sized("YUV4MPEG2 W16 H16 F25:1\n", 64));
    add("dv", sized("\x1f\x07\x00\xbf", 64));
    add("jp2", sized("\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a\x00\x00\x00\x14ftypjp2 ", 64));
    add("mj2", sized("\x00\x00\x00\x0cjP  \x0d\x0a\x87\x0a\x00\x00\x00\x14ftypmjp2", 64));
    add("jpc", sized("\xff\x4f\xff\x51\x00\x04\xff\x52\x00\x04\xff\x5c\x00\x04\xff\x90", 64));
    add("m4a", sized("\x00\x00\x00\x20ftypM4A \x00\x00\x00\x00", 64));
    add("3gp", sized("\x00\x00\x00\x14ftyp3gp4\x00\x00\x00\x00", 64));
    add("3gp-late", sized("\x00\x00\x00\x1cftypxxxx\x00\x00\x00\x00isomxxxx3gr6", 64));
    add("mov-qt", sized("\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00", 64));
    add("mp4-iso", sized("\x00\x00\x00\x14ftypisom\x00\x00\x00\x00", 64));
    add("mp4-cmaf", sized("\x00\x00\x00\x18ftypxxxx\x00\x00\x00\x00cmfc", 64));
    add("heif", sized("\x00\x00\x00\x14ftypmif1\x00\x00\x00\x00", 64));
    add("mov-atoms", "\x00\x00\x00\x08wide\x00\x00\x00\x10mdat12345678\x00\x00\x00\x08moov");
    add("mov-free", "\x00\x00\x00\x08free\x00\x00\x00\x08skip\x00\x00\x00\x08udta\x00\x00\x00\x08junk");
    add("qtif", "\x00\x00\x00\x10idsc\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10idat\x00\x00\x00\x00\x00\x00\x00\x00");
    add("matroska", sized("\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04\x42\xf3\x81\x08\x42\x82\x88matroska\x42\x87\x81\x04\x42\x85\x81\x02", 256));
    add("webm", sized("\x1a\x45\xdf\xa3\x9b\x42\x86\x81\x01\x42\xf7\x81\x01\x42\xf2\x81\x04\x42\xf3\x81\x08\x42\x82\x84webm\x42\x87\x81\x04\x42\x85\x81\x02", 256));
    var mxf = Builder{};
    mxf.zeros(100);
    mxf.put("\x06\x0e\x2b\x34\x02\x05\x01\x01\x0d\x01\x02\x01\x01\x02\x04\x00");
    mxf.padTo(2048);
    add("mxf", mxf.done());
    add("wavpack", sized("wvpk\x40\x00\x00\x00\x10\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0a\x04\x00\x00\x00\x00\x00\x00\x00\x00\x0a\x02", 256));
    add("av1-obu", sized("\x12\x00\x0a\x0b\x00\x00\x00\x24\xc4\xff\xdf\x00\x68\x02", 64));
    add("av1-annexb", sized("\x10\x0f\x02\x10\x00", 64));
    frames("adts", "\xff\xf1\x50\x80\x08\x1f\xfc" ++ "\x00" ** 57, 12, "");
    frames("loas", "\x56\xe0\x3d" ++ "\x20" ** 61, 12, "");
    frames("ac3", "\x0b\x77\x00\x00\x0a\x40" ++ "\x00" ** 314, 6, "");
    frames("eac3", "\x0b\x77\x00\x9f\x00\x80" ++ "\x00" ** 314, 6, "");
    frames("dts", "\x7f\xfe\x80\x01\x00\x3c\x3f\xf0\xb4\x00\x00\x00\x00\x00\x00\x00" ++ "\x00" ** 1008, 4, "");
    frames("mpeg-ps", "\x00\x00\x01\xba\x44\x00\x04\x00\x04\x01\x01\x89\xc3\xf8\x00\x00\x01\xe0\x00\x10" ++ "\x80" ** 16, 12, "");
    frames("mpeg-ts", "\x47\x40\x00\x10" ++ "\xff" ** 184, 20, "");
    frames("mpeg-ts192", "\x00\x00\x00\x00\x47\x40\x00\x10" ++ "\xff" ** 184, 20, "");
    frames("mpeg-video", "\x00\x00\x01\x00\x00\x0f\xff\xf8\x00\x00\x01\x01\x12\x34\x56\x78", 10, "\x00\x00\x01\xb3\x16\x00\xf0\x15\xff\xff\xe0\x18\x00\x00\x01\xb8\x00\x08\x00\x00");
    frames("mpeg4", "\x00\x00\x01\xb6\x10\x60\x50\x82", 10, "\x00\x00\x01\xb0\x01\x00\x00\x01\xb5\x09\x00\x00\x01\x00\x00\x00\x01\x20\x00\x84\x40\x06\x8a");
    frames("h263", "\x00\x00\x80\x02\x08\x00\x40\x10" ++ "\x55" ** 56, 8, "");
    frames("h264", "\x00\x00\x01\x41\x9a\x24\x6c\x41", 14, "\x00\x00\x00\x01\x67\x42\xc0\x1e\x00\x00\x01\x68\xce\x3c\x80\x00\x00\x01\x65\x88\x84\x00");
    frames("h265", "\x00\x00\x01\x02\x01\xd0\x10\x40", 14, "\x00\x00\x00\x01\x40\x01\x0c\x01\x00\x00\x01\x42\x01\x01\x01\x00\x00\x01\x44\x01\xc1\x72\x00\x00\x01\x26\x01\xaf\x00");
    frames("h266", "\x00\x00\x01\x00\x01\x12\x34", 14, "\x00\x00\x01\x00\x71\x00\x00\x00\x01\x00\x79\x00\x00\x00\x01\x00\x81\x00\x00\x00\x01\x00\x39\x00");
    frames("mp3-synth", "\xff\xfb\x90\x64" ++ "\x00" ** 413, 8, "");
    frames("mp3-free", "\xff\xfb\x00\x64" ++ "\x00" ** 200, 8, "");
    const sw = [_][]const u8{ "\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6\xd9\x00\xaa\x00\x62\xce\x6c", "\x00\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x00", "BEGIN:IMELODY", "Scenarist_SCC V1.0", ".RMF", ".ra\xfd", "FLV", "NIST", "Creative", "riff", "RF64", "GIF8", "\x89PNG\x0d\x0a\x1a\x0a", "Interplay MVE File\x1a\x00\x1a\x00\x00\x01\x33\x11", "#!AMR", "#!AMR-WB", "PSID", "gimp xcf", "\x8aMNG\x0d\x0a\x1a\x0a", "\x8bJNG\x0d\x0a\x1a\x0a", "/* XPM */", "\x59\xa6\x6a\x95", "BZh", "\x1f\x8b", "PK\x03\x04", "\x1f\x9d", "\x7fELF", "SNES-SPC700 Sound File Data", "caff\x00\x01", "Rar!", "NESM\x1a", "GYMX", "ZXAYEMUL", "GBS\x01", "Vgm\x20", "SAP\x0d\x0aAUTHOR\x20", "DKIF", "KSSX\x00", "%PDF-", "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1", "\x00\x00\x00\x01Bud1", "8BPS\x00\x01\x00\x00\x00\x00", "Extended Instrument: ", "DC2N-TAP-RAW", "wW\x10\x00", "YUV4MPEG2" };
    for (sw, 0..) |m, i| {
        const n = std.fmt.allocPrint(A, "magic-{d}", .{i}) catch unreachable;
        add(n, sized(m, 64));
    }
    for ([_][]const u8{ "WAVE", "AVI ", "WEBP", "RMID", "QLCM", "CDXA", "4XMV", "XWMA" }) |k| {
        const n = std.fmt.allocPrint(A, "riff-{s}", .{k}) catch unreachable;
        add(n, sized("RIFF\x00\x10\x00\x00" ++ "    ", 64));
        @memcpy(@constCast(blobs.items[blobs.items.len - 1].data[8..12]), k);
    }
    add("avf0", sized("AVF0\x00\x10\x00\x00AVI ", 64));
}

fn encoders() void {
    const a = "audiotestsrc num-buffers=30 samplesperbuffer=1152 wave=sine ! audio/x-raw,rate=44100,channels=2 ! ";
    const v = "videotestsrc num-buffers=4 ! video/x-raw,width=64,height=48,framerate=25/1 ! ";
    encode("mp3", a ++ "lamemp3enc");
    encode("mp3-id3", a ++ "lamemp3enc ! id3v2mux");
    encode("mp3-ape", a ++ "lamemp3enc ! apev2mux");
    encode("mp2", a ++ "twolamemp2enc");
    encode("flac", a ++ "flacenc");
    encode("wav", a ++ "wavenc");
    encode("wavpack", a ++ "wavpackenc");
    encode("ogg-vorbis", a ++ "vorbisenc ! oggmux");
    encode("ogg-opus", "audiotestsrc num-buffers=30 ! audio/x-raw,rate=48000 ! opusenc ! oggmux");
    encode("ogg-speex", "audiotestsrc num-buffers=30 ! audio/x-raw,rate=16000,channels=1 ! speexenc ! oggmux");
    encode("ogg-flac", a ++ "flacenc ! oggmux");
    encode("ogg-theora", v ++ "videoconvert ! theoraenc ! oggmux");
    encode("webm", v ++ "videoconvert ! vp8enc ! webmmux");
    encode("mkv-flac", a ++ "flacenc ! matroskamux");
    encode("mkv-audio", a ++ "vorbisenc ! matroskamux");
    encode("mp4-mp3", a ++ "lamemp3enc ! mp4mux");
    encode("mov-jpeg", v ++ "jpegenc ! qtmux");
    encode("avi", v ++ "jpegenc ! avimux");
    encode("flv", a ++ "lamemp3enc ! flvmux");
    encode("jpeg", "videotestsrc num-buffers=1 ! video/x-raw,width=64,height=48 ! jpegenc");
    encode("png", "videotestsrc num-buffers=1 ! video/x-raw,width=64,height=48 ! pngenc");
    encode("y4m", v ++ "y4menc");
    encode("multipart", v ++ "jpegenc ! multipartmux");
    encode("ivf", v ++ "videoconvert ! vp8enc ! ivfmux");
}

const Rec = struct {
    blob: []const u8,
    known: bool,
    lines: std.ArrayList(u8) = .empty,
};

fn peek(data: c.gpointer, off: i64, size: c.guint) callconv(.c) [*c]const u8 {
    const r: *Rec = @ptrCast(@alignCast(data));
    const len: i64 = @intCast(r.blob.len);
    var start = off;
    if (off < 0) {
        if (!r.known) return null;
        start = len + off;
    }
    if (start < 0 or start + @as(i64, size) > len) return null;
    return r.blob.ptr + @as(usize, @intCast(start));
}

fn suggest(data: c.gpointer, prob: c.guint, caps: [*c]c.GstCaps) callconv(.c) void {
    const r: *Rec = @ptrCast(@alignCast(data));
    const s = c.gst_caps_to_string(caps);
    defer c.g_free(s);
    const line = std.fmt.allocPrint(A, "    {d} {s}\n", .{ prob, z(s) }) catch unreachable;
    r.lines.appendSlice(A, line) catch unreachable;
}

fn length(data: c.gpointer) callconv(.c) u64 {
    const r: *Rec = @ptrCast(@alignCast(data));
    return if (r.known) r.blob.len else 0;
}

fn padded(d: []const u8) []const u8 {
    const m = A.alloc(u8, d.len + 256) catch unreachable;
    @memset(m, 0);
    @memcpy(m[0..d.len], d);
    return m[0..d.len];
}

fn cmpFactory(_: void, a: *c.GstPluginFeature, b: *c.GstPluginFeature) bool {
    return std.mem.order(u8, z(c.gst_plugin_feature_get_name(a)), z(c.gst_plugin_feature_get_name(b))) == .lt;
}

fn pluginFeatures(name: [*c]const u8) void {
    const reg = c.gst_registry_get();
    const plugin = c.gst_registry_find_plugin(reg, name);
    if (plugin == null) return out("plugin {s} missing", .{z(name)});
    out("plugin {s} desc {s} source {s} license {s}", .{ z(name), z(c.gst_plugin_get_description(plugin)), z(c.gst_plugin_get_source(plugin)), z(c.gst_plugin_get_license(plugin)) });
    c.gst_object_unref(plugin);
    const list = c.gst_registry_get_feature_list_by_plugin(reg, name);
    var names: std.ArrayList([]const u8) = .empty;
    var l = list;
    while (l != null) : (l = l[0].next) {
        const f: *c.GstPluginFeature = @ptrCast(@alignCast(l[0].data));
        const line = std.fmt.allocPrint(A, "  feature {s} {s} rank {d}", .{ z(c.gst_plugin_feature_get_name(f)), z(c.g_type_name(c.G_TYPE_FROM_INSTANCE(f))), c.gst_plugin_feature_get_rank(f) }) catch unreachable;
        names.append(A, line) catch unreachable;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |n| out("{s}", .{n});
    c.gst_plugin_feature_list_free(list);
}

pub fn main() void {
    c.gst_init(null, null);
    pluginFeatures("pbtypes");
    pluginFeatures("typefindfunctions");
    encoders();
    synthetic();
    const list = c.gst_type_find_factory_get_list();
    var facts: std.ArrayList(*c.GstPluginFeature) = .empty;
    var l = list;
    while (l != null) : (l = l[0].next) {
        const f: *c.GstPluginFeature = @ptrCast(@alignCast(l[0].data));
        const plugin = c.gst_plugin_feature_get_plugin_name(f);
        if (std.mem.eql(u8, z(plugin), "typefindfunctions")) facts.append(A, f) catch unreachable;
    }
    std.mem.sort(*c.GstPluginFeature, facts.items, {}, cmpFactory);
    out("factories {d}", .{facts.items.len});
    for (facts.items) |f| {
        const tf: *c.GstTypeFindFactory = @ptrCast(@alignCast(f));
        const ext = c.gst_type_find_factory_get_extensions(tf);
        var exts: [512]u8 = undefined;
        var n: usize = 0;
        if (ext != null) {
            var i: usize = 0;
            while (ext[i] != null) : (i += 1) {
                const w = std.fmt.bufPrint(exts[n..], "{s},", .{z(ext[i])}) catch break;
                n += w.len;
            }
        }
        const caps = c.gst_type_find_factory_get_caps(tf);
        const cs = if (caps != null) c.gst_caps_to_string(caps) else null;
        out("factory {s} rank {d} func {d} ext {s} caps {s}", .{ z(c.gst_plugin_feature_get_name(f)), c.gst_plugin_feature_get_rank(f), c.gst_type_find_factory_has_function(tf), exts[0..n], z(cs) });
        c.g_free(cs);
    }
    for (blobs.items) |b| {
        const data = padded(b.data);
        for ([_]bool{ true, false }) |known| {
            out("blob {s} size {d} known {}", .{ b.name, b.data.len, known });
            for (facts.items) |f| {
                if (!known and std.mem.eql(u8, z(c.gst_plugin_feature_get_name(f)), "application/x-ssa")) continue;
                var r = Rec{ .blob = data, .known = known };
                var find = c.GstTypeFind{ .peek = peek, .suggest = suggest, .data = &r, .get_length = length, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
                c.gst_type_find_factory_call_function(@ptrCast(@alignCast(f)), &find);
                if (r.lines.items.len > 0) out("  {s}\n{s}", .{ z(c.gst_plugin_feature_get_name(f)), r.lines.items[0 .. r.lines.items.len - 1] });
            }
        }
        var prob: c.GstTypeFindProbability = 0;
        const best = c.gst_type_find_helper_for_data(null, data.ptr, data.len, &prob);
        const s = if (best != null) c.gst_caps_to_string(best) else null;
        out("  best {d} {s}", .{ prob, z(s) });
        c.g_free(s);
        if (best != null) c.gst_mini_object_unref(@ptrCast(best));
    }
    c.gst_plugin_feature_list_free(list);
    out("done", .{});
}
