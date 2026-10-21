const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const NONE = @as(?*anyopaque, null);

fn show(label: []const u8, l: [*c]const c.GstTagList) void {
    if (l == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const s = c.gst_tag_list_to_string(l);
    out("  {s} {s}", .{ label, str(s) });
    c.g_free(s);
}

fn bufText(b: [*c]c.GstBuffer) void {
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &info);
    out("--- {d} bytes\n{s}\n---", .{ info.size, info.data[0..info.size] });
}

fn fromText(t: []const u8) [*c]c.GstTagList {
    const b = c.gst_buffer_new_allocate(null, t.len, null);
    _ = c.gst_buffer_fill(b, 0, t.ptr, t.len);
    defer c.gst_buffer_unref(b);
    return c.gst_tag_list_from_xmp_buffer(b);
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    c.gst_init(null, null);
    const s = c.gst_tag_xmp_list_schemas();
    var i: usize = 0;
    while (s[i] != null) : (i += 1) out("schema {s}", .{str(s[i])});
    const l = c.gst_tag_list_new_empty();
    const dt = c.gst_date_time_new(2.0, 2011, 3, 4, 5, 6, 7.25);
    const dt2 = c.gst_date_time_new_ymd(2012, 1, 2);
    const dt3 = c.gst_date_time_new(0.0, 2013, 5, 6, 7, 8, 9.5);
    const dt4 = c.gst_date_time_new(-3.5, 2014, 7, 8, 9, 10, 11.0);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_ARTIST, "Artist <One>", c.GST_TAG_ARTIST, "Two & Co", c.GST_TAG_COPYRIGHT, "(c) me", c.GST_TAG_DATE_TIME, dt, c.GST_TAG_DESCRIPTION, "desc", c.GST_TAG_KEYWORDS, "k1", c.GST_TAG_KEYWORDS, "k2", c.GST_TAG_TITLE, "Title", c.GST_TAG_VIDEO_CODEC, "h264", NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_USER_RATING, @as(c.guint, 80), c.GST_TAG_DEVICE_MANUFACTURER, "Maker", c.GST_TAG_DEVICE_MODEL, "Model X", c.GST_TAG_APPLICATION_NAME, "App", c.GST_TAG_IMAGE_ORIENTATION, "rotate-90", NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_GEO_LOCATION_LATITUDE, @as(f64, -23.5), c.GST_TAG_GEO_LOCATION_LONGITUDE, @as(f64, 46.6375), c.GST_TAG_CAPTURING_EXPOSURE_COMPENSATION, @as(f64, -0.333333), c.GST_TAG_GEO_LOCATION_ELEVATION, @as(f64, -120.25), c.GST_TAG_GEO_LOCATION_MOVEMENT_SPEED, @as(f64, 12.5), c.GST_TAG_GEO_LOCATION_MOVEMENT_DIRECTION, @as(f64, 90.5), c.GST_TAG_GEO_LOCATION_CAPTURE_DIRECTION, @as(f64, 180.0), NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_GEO_LOCATION_COUNTRY, "Italy", c.GST_TAG_GEO_LOCATION_CITY, "Rome", c.GST_TAG_GEO_LOCATION_SUBLOCATION, "Center", NONE);
    show("input", l);
    const b = c.gst_tag_list_to_xmp_buffer(l, 1, null);
    bufText(b);
    const back = c.gst_tag_list_from_xmp_buffer(b);
    show("back", back);
    c.gst_tag_list_unref(back);
    c.gst_buffer_unref(b);
    const b2 = c.gst_tag_list_to_xmp_buffer(l, 0, null);
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b2, &info, c.GST_MAP_READ);
    out("  rw size {d} tail {s}", .{ info.size, info.data[info.size - 20 .. info.size] });
    c.gst_buffer_unmap(b2, &info);
    show("back rw", c.gst_tag_list_from_xmp_buffer(b2));
    c.gst_buffer_unref(b2);
    var sub = [_][*c]const u8{ "exif", "dc", "bogus", null };
    const b3 = c.gst_tag_list_to_xmp_buffer(l, 1, &sub);
    bufText(b3);
    c.gst_buffer_unref(b3);
    const l2 = c.gst_tag_list_new_empty();
    c.gst_tag_list_add(l2, c.GST_TAG_MERGE_APPEND, c.GST_TAG_DATE_TIME, dt2, c.GST_TAG_DATE_TIME, dt3, c.GST_TAG_DATE_TIME, dt4, c.GST_TAG_IMAGE_ORIENTATION, "bogus", c.GST_TAG_TITLE, "one", NONE);
    const b4 = c.gst_tag_list_to_xmp_buffer(l2, 1, null);
    bufText(b4);
    show("back2", c.gst_tag_list_from_xmp_buffer(b4));
    c.gst_buffer_unref(b4);
    const head = "<?xpacket begin=\"\xef\xbb\xbf\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\n<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n";
    const tail = "</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"r\"?>";
    const cases = [_][]const u8{
        head ++ "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" dc:title=\"Attr Title\" xmp:Rating=\"5\" tiff:Orientation=\"3\" exif:GPSAltitudeRef=\"1\" exif:GPSAltitude=\"100/3\" exif:GPSSpeed=\"10/1\" exif:GPSSpeedRef=\"M\"/>\n" ++ tail,
        head ++ "<rdf:Description>\n<exif:GPSLatitude>12,30.5S</exif:GPSLatitude>\n<exif:GPSLongitude>40,20,10E</exif:GPSLongitude>\n<exif:GPSTrackRef>M</exif:GPSTrackRef>\n<exif:GPSTrack>5/1</exif:GPSTrack>\n<exif:GPSImgDirection>45/2</exif:GPSImgDirection>\n<exif:GPSImgDirectionRef>T</exif:GPSImgDirectionRef>\n<exif:GPSSpeedRef>N</exif:GPSSpeedRef>\n<exif:GPSSpeed>3/1</exif:GPSSpeed>\n<xmp:Rating>150</xmp:Rating>\n<tiff:Orientation>9</tiff:Orientation>\n<exif:ExposureBiasValue>1/3</exif:ExposureBiasValue>\n<dc:date><rdf:Seq><rdf:li>2001-02-03T04:05:06Z</rdf:li><rdf:li></rdf:li></rdf:Seq></dc:date>\n</rdf:Description>\n" ++ tail,
        head ++ "<rdf:Description>\n<Iptc4xmpExt:LocationShown><rdf:Bag><rdf:li rdf:parseType=\"Resource\"><LocationDetails:City>Paris</LocationDetails:City><LocationDetails:Country>FR</LocationDetails:Country></rdf:li></rdf:Bag></Iptc4xmpExt:LocationShown>\n<dc:subject><rdf:Bag><rdf:li>a</rdf:li><rdf:li>b</rdf:li></rdf:Bag></dc:subject>\n<photoshop:City>Lyon</photoshop:City>\n</rdf:Description>\n" ++ tail,
        "no packet here at all",
        head ++ "<rdf:Description><dc:title>x</dc:title>",
        head ++ "<rdf:Description><dc:title>x</dc:title" ++ tail,
        "<?xpacket begin=\"\" <dc:title>x</dc:title><?xpacket end=\"r\"?>",
    };
    for (cases, 0..) |cs, k| {
        var lbl: [16]u8 = undefined;
        show(std.fmt.bufPrint(&lbl, "case {d}", .{k}) catch "case", fromText(cs));
    }
    out("crit", .{});
    _ = c.gst_tag_list_to_xmp_buffer(null, 0, null);
    _ = c.gst_tag_list_from_xmp_buffer(null);
    out("done", .{});
}
