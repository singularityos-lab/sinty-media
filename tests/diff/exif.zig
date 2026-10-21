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

fn hex(label: []const u8, b: [*c]c.GstBuffer) void {
    if (b == null) {
        out("  {s} (null)", .{label});
        return;
    }
    const n = c.gst_buffer_n_memory(b);
    var i: c.guint = 0;
    var sizes: [256]u8 = undefined;
    var pos: usize = 0;
    while (i < n) : (i += 1) {
        const m = c.gst_buffer_peek_memory(b, i);
        const s = std.fmt.bufPrint(sizes[pos..], " {d}/{d}", .{ m.*.size, m.*.maxsize }) catch break;
        pos += s.len;
    }
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &info);
    out("  {s} {d} bytes, mem{s}", .{ label, info.size, sizes[0..pos] });
    var off: usize = 0;
    while (off < info.size) : (off += 32) {
        const end = @min(off + 32, info.size);
        out("    {x}", .{info.data[off..end]});
    }
}

fn wrap(bytes: []const u8) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, bytes.len, null);
    _ = c.gst_buffer_fill(b, 0, bytes.ptr, bytes.len);
    return b;
}

fn parse(label: []const u8, bytes: []const u8, order: c.gint, base: u32) void {
    const b = wrap(bytes);
    defer c.gst_buffer_unref(b);
    const l = c.gst_tag_list_from_exif_buffer(b, order, base);
    show(label, l);
    if (l != null) c.gst_tag_list_unref(l);
}

const Ifd = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    be: bool = false,

    fn u16v(self: *Ifd, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.len..][0..2], v, if (self.be) .big else .little);
        self.len += 2;
    }

    fn u32v(self: *Ifd, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, if (self.be) .big else .little);
        self.len += 4;
    }

    fn raw(self: *Ifd, d: []const u8) void {
        @memcpy(self.buf[self.len..][0..d.len], d);
        self.len += d.len;
    }

    fn entry(self: *Ifd, tag: u16, kind: u16, count: u32, val: u32) void {
        self.u16v(tag);
        self.u16v(kind);
        self.u32v(count);
        self.u32v(val);
    }

    fn entryRaw(self: *Ifd, tag: u16, kind: u16, count: u32, d: [4]u8) void {
        self.u16v(tag);
        self.u16v(kind);
        self.u32v(count);
        self.raw(&d);
    }

    fn short(self: *Ifd, tag: u16, v: u16) void {
        var d = [4]u8{ 0, 0, 0, 0 };
        std.mem.writeInt(u16, d[0..2], v, if (self.be) .big else .little);
        self.entryRaw(tag, 3, 1, d);
    }

    fn bytes(self: *Ifd) []const u8 {
        return self.buf[0..self.len];
    }
};

fn fullList() [*c]c.GstTagList {
    const l = c.gst_tag_list_new_empty();
    const dt = c.gst_date_time_new(2.0, 2011, 3, 4, 5, 6, 7.25);
    const sbuf = wrap("maker-note-bytes!");
    const sample = c.gst_sample_new(sbuf, null, null, null);
    var frac = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&frac, c.gst_fraction_get_type());
    c.gst_value_set_fraction(&frac, 1, 250);
    c.gst_tag_list_add_value(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_CAPTURING_SHUTTER_SPEED, &frac);
    c.g_value_unset(&frac);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_DESCRIPTION, "A description", c.GST_TAG_DEVICE_MANUFACTURER, "Maker", c.GST_TAG_DEVICE_MODEL, "M1", c.GST_TAG_IMAGE_ORIENTATION, "rotate-90", c.GST_TAG_APPLICATION_NAME, "Sinty Cam", c.GST_TAG_DATE_TIME, dt, c.GST_TAG_ARTIST, "Ünïcødé Artist", c.GST_TAG_COPYRIGHT, "(c)", NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_IMAGE_HORIZONTAL_PPI, @as(f64, 300.0), c.GST_TAG_IMAGE_VERTICAL_PPI, @as(f64, 72.5), NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_CAPTURING_FOCAL_RATIO, @as(f64, 2.8), c.GST_TAG_CAPTURING_EXPOSURE_PROGRAM, "aperture-priority", c.GST_TAG_CAPTURING_ISO_SPEED, @as(c.gint, 400), c.GST_TAG_CAPTURING_EXPOSURE_COMPENSATION, @as(f64, -0.6666), c.GST_TAG_CAPTURING_METERING_MODE, "spot", c.GST_TAG_CAPTURING_FLASH_FIRED, @as(c.gboolean, 1), c.GST_TAG_CAPTURING_FLASH_MODE, "auto", c.GST_TAG_CAPTURING_FOCAL_LENGTH, @as(f64, 35.5), NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_APPLICATION_DATA, sample, c.GST_TAG_CAPTURING_SOURCE, "dsc", c.GST_TAG_CAPTURING_EXPOSURE_MODE, "auto-bracket", c.GST_TAG_CAPTURING_WHITE_BALANCE, "manual", c.GST_TAG_CAPTURING_LIGHT_SOURCE, "D65", c.GST_TAG_CAPTURING_DIGITAL_ZOOM_RATIO, @as(f64, 1.5), c.GST_TAG_CAPTURING_FOCAL_LENGTH_35_MM, @as(f64, 50.7), c.GST_TAG_CAPTURING_SCENE_CAPTURE_TYPE, "night-scene", c.GST_TAG_CAPTURING_GAIN_ADJUSTMENT, "high-gain-down", c.GST_TAG_CAPTURING_CONTRAST, "hard", c.GST_TAG_CAPTURING_SATURATION, "low-saturation", c.GST_TAG_CAPTURING_SHARPNESS, "soft", NONE);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, c.GST_TAG_GEO_LOCATION_LATITUDE, @as(f64, -23.5123), c.GST_TAG_GEO_LOCATION_LONGITUDE, @as(f64, 46.6375), c.GST_TAG_GEO_LOCATION_ELEVATION, @as(f64, -120.25), c.GST_TAG_GEO_LOCATION_MOVEMENT_SPEED, @as(f64, 12.5), c.GST_TAG_GEO_LOCATION_MOVEMENT_DIRECTION, @as(f64, 90.5), c.GST_TAG_GEO_LOCATION_CAPTURE_DIRECTION, @as(f64, 180.25), c.GST_TAG_GEO_LOCATION_HORIZONTAL_ERROR, @as(f64, 3.75), NONE);
    c.gst_sample_unref(sample);
    c.gst_buffer_unref(sbuf);
    c.gst_date_time_unref(dt);
    return l;
}

fn roundTrip(label: []const u8, l: [*c]const c.GstTagList, order: c.gint, base: u32) void {
    const b = c.gst_tag_list_to_exif_buffer(l, order, base);
    hex(label, b);
    if (b == null) return;
    const back = c.gst_tag_list_from_exif_buffer(b, order, base);
    show("back", back);
    if (back != null) c.gst_tag_list_unref(back);
    c.gst_buffer_unref(b);
}

fn handmade() void {
    var a = Ifd{};
    a.u16v(6);
    a.entry(0x11A, 5, 1, 2 + 6 * 12 + 4);
    a.entry(0x11B, 5, 1, 2 + 6 * 12 + 12);
    a.short(0x128, 3);
    a.entry(0x10F, 2, 3, 0x0041_4243);
    a.entry(0x110, 2, 9, 2 + 6 * 12 + 20);
    a.entry(0x8769, 4, 1, 2 + 6 * 12 + 30);
    a.u32v(0);
    a.u32v(254);
    a.u32v(1);
    a.u32v(72);
    a.u32v(2);
    a.raw("Mod\xe9l 7\x00\x00\x00");
    a.u16v(4);
    a.entry(0x8827, 3, 1, 800);
    a.short(0x8830, 3);
    a.entry(0x9000, 7, 4, 0x3033_3230);
    a.short(0x9209, 0x19);
    a.u32v(0);
    parse("cm-then-exif", a.bytes(), c.G_LITTLE_ENDIAN, 0);
    parse("cm-then-exif base8", a.bytes(), c.G_LITTLE_ENDIAN, 8);

    var g = Ifd{ .be = true };
    g.u16v(1);
    g.entry(0x8825, 4, 1, 2 + 12 + 4);
    g.u32v(0);
    g.u16v(9);
    const gstart: u32 = 2 + 12 + 4 + 2 + 9 * 12 + 4;
    g.entryRaw(0x1, 2, 2, .{ 'S', 0, 0, 0 });
    g.entry(0x2, 5, 3, gstart);
    g.entryRaw(0x3, 2, 2, .{ 'X', 0, 0, 0 });
    g.entry(0x4, 5, 3, gstart);
    g.entryRaw(0x5, 1, 1, .{ 1, 0, 0, 0 });
    g.entry(0x6, 5, 1, gstart + 24);
    g.entryRaw(0xC, 2, 2, .{ 'N', 0, 0, 0 });
    g.entry(0xD, 5, 1, gstart + 32);
    g.entryRaw(0x10, 2, 2, .{ 'M', 0, 0, 0 });
    g.u32v(0);
    g.u32v(45);
    g.u32v(1);
    g.u32v(30);
    g.u32v(1);
    g.u32v(15);
    g.u32v(2);
    g.u32v(1001);
    g.u32v(10);
    g.u32v(20);
    g.u32v(1);
    parse("gps be", g.bytes(), c.G_BIG_ENDIAN, 0);

    var h = Ifd{};
    h.u16v(5);
    h.entry(0x0, 5, 1, 2 + 5 * 12 + 4);
    h.entry(0x110, 2, 200, 9999);
    h.entry(0x8825, 4, 1, 2);
    h.entry(0x9999, 3, 1, 0);
    h.entry(0x8298, 2, 4, 0x0000_6362);
    h.u32v(0);
    h.u32v(10);
    h.u32v(4);
    parse("odd", h.bytes(), c.G_LITTLE_ENDIAN, 0);
    parse("truncated", h.bytes()[0..30], c.G_LITTLE_ENDIAN, 0);
    parse("empty", h.bytes()[0..0], c.G_LITTLE_ENDIAN, 0);

    var t = Ifd{};
    t.raw("II");
    t.u16v(42);
    t.u32v(8);
    t.u16v(2);
    t.entry(0x10F, 2, 6, 8 + 2 + 2 * 12 + 4);
    t.short(0x112, 8);
    t.u32v(0);
    t.raw("Canon\x00");
    const tb = wrap(t.bytes());
    show("tiff", c.gst_tag_list_from_exif_buffer_with_tiff_header(tb));
    c.gst_buffer_unref(tb);
    const bad = wrap("MM\x00\x2b\x00\x00\x00\x08xxxx");
    show("tiff magic", c.gst_tag_list_from_exif_buffer_with_tiff_header(bad));
    c.gst_buffer_unref(bad);
    const bad2 = wrap("QQ\x00\x2a");
    show("tiff endian", c.gst_tag_list_from_exif_buffer_with_tiff_header(bad2));
    c.gst_buffer_unref(bad2);
}

fn fuzz(seed_list: [*c]const c.GstTagList) void {
    const b = c.gst_tag_list_to_exif_buffer(seed_list, c.G_LITTLE_ENDIAN, 0);
    defer c.gst_buffer_unref(b);
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    var base: [2048]u8 = undefined;
    const n = info.size;
    @memcpy(base[0..n], info.data[0..n]);
    c.gst_buffer_unmap(b, &info);
    var prng = std.Random.DefaultPrng.init(0x5171);
    const rnd = prng.random();
    var k: usize = 0;
    while (k < 300) : (k += 1) {
        var mut = base;
        const flips = rnd.intRangeAtMost(usize, 1, 6);
        var f: usize = 0;
        while (f < flips) : (f += 1) mut[rnd.uintLessThan(usize, n)] = rnd.int(u8);
        const len = if (k % 7 == 0) rnd.uintLessThan(usize, n) else n;
        var lb: [16]u8 = undefined;
        parse(std.fmt.bufPrint(&lb, "fuzz{d}", .{k}) catch "fuzz", mut[0..len], if (k % 5 == 0) c.G_BIG_ENDIAN else c.G_LITTLE_ENDIAN, 0);
    }
}

pub fn main() void {
    _ = c.g_setenv("GST_PLUGIN_SYSTEM_PATH", "/nonexistent-sinty", 1);
    _ = c.g_setenv("GST_REGISTRY", "/nonexistent-sinty/registry.bin", 1);
    _ = c.g_setenv("TZ", "Europe/Rome", 1);
    c.gst_init(null, null);
    c.gst_tag_register_musicbrainz_tags();
    const l = fullList();
    show("input", l);
    roundTrip("le0", l, c.G_LITTLE_ENDIAN, 0);
    roundTrip("be0", l, c.G_BIG_ENDIAN, 0);
    roundTrip("le12", l, c.G_LITTLE_ENDIAN, 12);
    const tiff = c.gst_tag_list_to_exif_buffer_with_tiff_header(l);
    hex("tiff", tiff);
    show("tiff back", c.gst_tag_list_from_exif_buffer_with_tiff_header(tiff));
    c.gst_buffer_unref(tiff);
    const e = c.gst_tag_list_new_empty();
    hex("empty", c.gst_tag_list_to_exif_buffer(e, c.G_LITTLE_ENDIAN, 0));
    c.gst_tag_list_add(e, c.GST_TAG_MERGE_APPEND, c.GST_TAG_TITLE, "not exif", NONE);
    hex("title only", c.gst_tag_list_to_exif_buffer(e, c.G_LITTLE_ENDIAN, 0));
    const dt = c.gst_date_time_new_y(1999);
    c.gst_tag_list_add(e, c.GST_TAG_MERGE_APPEND, c.GST_TAG_DATE_TIME, dt, c.GST_TAG_ARTIST, "a", c.GST_TAG_ARTIST, "b", c.GST_TAG_COPYRIGHT, "abc", c.GST_TAG_IMAGE_ORIENTATION, "bogus", c.GST_TAG_CAPTURING_FLASH_FIRED, @as(c.gboolean, 0), c.GST_TAG_CAPTURING_SOURCE, "other", c.GST_TAG_GEO_LOCATION_LATITUDE, @as(f64, 0.0), NONE);
    c.gst_date_time_unref(dt);
    roundTrip("partial", e, c.G_LITTLE_ENDIAN, 0);
    const z = wrap("\x00\x00");
    show("bad order", c.gst_tag_list_from_exif_buffer(z, 1000, 0));
    c.gst_buffer_unref(z);
    handmade();
    fuzz(l);
    c.gst_tag_list_unref(e);
    c.gst_tag_list_unref(l);
}
