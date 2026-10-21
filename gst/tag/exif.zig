const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tags = @import("tags.zig");
const ev = @import("exifvalues.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const libm = @import("../libm.zig");
const pow = libm.pow;
const log2 = libm.log2;

const NONE = @as(?*anyopaque, null);
const LE: c_int = c.G_LITTLE_ENDIAN;
const BE: c_int = c.G_BIG_ENDIAN;

const T_BYTE = 1;
const T_ASCII = 2;
const T_SHORT = 3;
const T_LONG = 4;
const T_RATIONAL = 5;
const T_UNDEFINED = 7;
const T_SLONG = 9;
const T_SRATIONAL = 10;

const GPS_LATITUDE_REF = 0x1;
const GPS_LATITUDE = 0x2;
const GPS_LONGITUDE_REF = 0x3;
const GPS_LONGITUDE = 0x4;
const GPS_ALTITUDE_REF = 0x5;
const GPS_ALTITUDE = 0x6;
const GPS_SPEED_REF = 0xC;
const GPS_SPEED = 0xD;
const GPS_TRACK_REF = 0xE;
const GPS_TRACK = 0xF;
const GPS_IMAGE_DIRECTION_REF = 0x10;
const GPS_IMAGE_DIRECTION = 0x11;
const GPS_HORIZONTAL_ERROR = 0x1F;
const XRESOLUTION = 0x11A;
const YRESOLUTION = 0x11B;
const PHOTOGRAPHIC_SENSITIVITY = 0x8827;
const IFD_EXIF = 0x8769;
const IFD_GPS = 0x8825;
const VERSION = 0x9000;
const FLASHPIX_VERSION = 0xA000;

const Data = extern struct { tag: u16 = 0, kind: u16 = 0, count: u32 = 0, offset: u32 = 0, raw: [*c]const u8 = null };

const Writer = struct { tags: c.GstByteWriter, data: c.GstByteWriter, order: c_int, total: c.guint };

const Reader = struct { list: [*c]c.GstTagList, buffer: [*c]c.GstBuffer, base: u32, order: c_int, pending: ?*c.GSList };

const Ser = *const fn (*Writer, [*c]const c.GstTagList, *const Match) void;
const De = *const fn (*Reader, *c.GstByteReader, *const Match, *Data) c.gint;

const Match = struct { gst: [*c]const u8, tag: u16, kind: u16, ref: u16 = 0, ser: ?Ser = null, de: ?De = null };

const IFD0 = [_]Match{
    .{ .gst = c.GST_TAG_IMAGE_HORIZONTAL_PPI, .tag = XRESOLUTION, .kind = T_RATIONAL, .de = dePending },
    .{ .gst = c.GST_TAG_IMAGE_VERTICAL_PPI, .tag = YRESOLUTION, .kind = T_RATIONAL, .de = dePending },
    .{ .gst = null, .tag = 0x128, .kind = T_SHORT, .de = deResolution },
    .{ .gst = c.GST_TAG_DESCRIPTION, .tag = 0x10E, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_DEVICE_MANUFACTURER, .tag = 0x10F, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_DEVICE_MODEL, .tag = 0x110, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_IMAGE_ORIENTATION, .tag = 0x112, .kind = T_SHORT, .ser = mapSer(.orientation), .de = mapDe(.orientation) },
    .{ .gst = c.GST_TAG_APPLICATION_NAME, .tag = 0x131, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_DATE_TIME, .tag = 0x132, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_ARTIST, .tag = 0x13B, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_COPYRIGHT, .tag = 0x8298, .kind = T_ASCII },
    .{ .gst = null, .tag = IFD_EXIF, .kind = T_LONG },
    .{ .gst = null, .tag = IFD_GPS, .kind = T_LONG },
};

const EXIF = [_]Match{
    .{ .gst = c.GST_TAG_CAPTURING_SHUTTER_SPEED, .tag = 0x829A, .kind = T_RATIONAL },
    .{ .gst = c.GST_TAG_CAPTURING_FOCAL_RATIO, .tag = 0x829D, .kind = T_RATIONAL },
    .{ .gst = c.GST_TAG_CAPTURING_EXPOSURE_PROGRAM, .tag = 0x8822, .kind = T_SHORT, .ser = mapSer(.exposure_program), .de = mapDe(.exposure_program) },
    .{ .gst = c.GST_TAG_CAPTURING_ISO_SPEED, .tag = PHOTOGRAPHIC_SENSITIVITY, .kind = T_SHORT, .de = dePending },
    .{ .gst = c.GST_TAG_CAPTURING_ISO_SPEED, .tag = 0x8830, .kind = T_SHORT, .ser = serSensitivity, .de = deSensitivity },
    .{ .gst = c.GST_TAG_CAPTURING_ISO_SPEED, .tag = 0x8833, .kind = T_LONG },
    .{ .gst = null, .tag = VERSION, .kind = T_UNDEFINED },
    .{ .gst = c.GST_TAG_DATE_TIME, .tag = 0x9003, .kind = T_ASCII },
    .{ .gst = c.GST_TAG_CAPTURING_SHUTTER_SPEED, .tag = 0x9201, .kind = T_SRATIONAL, .ser = serShutter, .de = deShutter },
    .{ .gst = c.GST_TAG_CAPTURING_FOCAL_RATIO, .tag = 0x9202, .kind = T_RATIONAL, .ser = serAperture, .de = deAperture },
    .{ .gst = c.GST_TAG_CAPTURING_EXPOSURE_COMPENSATION, .tag = 0x9204, .kind = T_SRATIONAL },
    .{ .gst = c.GST_TAG_CAPTURING_METERING_MODE, .tag = 0x9207, .kind = T_SHORT, .ser = mapSer(.metering), .de = mapDe(.metering) },
    .{ .gst = c.GST_TAG_CAPTURING_FLASH_FIRED, .tag = 0x9209, .kind = T_SHORT, .ser = serFlash, .de = deFlash },
    .{ .gst = c.GST_TAG_CAPTURING_FOCAL_LENGTH, .tag = 0x920A, .kind = T_RATIONAL },
    .{ .gst = c.GST_TAG_APPLICATION_DATA, .tag = 0x927C, .kind = T_UNDEFINED },
    .{ .gst = null, .tag = FLASHPIX_VERSION, .kind = T_UNDEFINED },
    .{ .gst = c.GST_TAG_CAPTURING_SOURCE, .tag = 0xA300, .kind = T_UNDEFINED, .ser = mapSer(.source), .de = mapDe(.source) },
    .{ .gst = c.GST_TAG_CAPTURING_SOURCE, .tag = 0xA301, .kind = T_UNDEFINED, .ser = serSceneType, .de = deSceneType },
    .{ .gst = c.GST_TAG_CAPTURING_EXPOSURE_MODE, .tag = 0xA402, .kind = T_SHORT, .ser = mapSer(.exposure_mode), .de = mapDe(.exposure_mode) },
    .{ .gst = c.GST_TAG_CAPTURING_WHITE_BALANCE, .tag = 0xA403, .kind = T_SHORT, .ser = mapSer(.white_balance), .de = mapDe(.white_balance) },
    .{ .gst = c.GST_TAG_CAPTURING_LIGHT_SOURCE, .tag = 0x9208, .kind = T_SHORT, .ser = mapSer(.light), .de = mapDe(.light) },
    .{ .gst = c.GST_TAG_CAPTURING_DIGITAL_ZOOM_RATIO, .tag = 0xA404, .kind = T_RATIONAL },
    .{ .gst = c.GST_TAG_CAPTURING_FOCAL_LENGTH_35_MM, .tag = 0xA405, .kind = T_SHORT },
    .{ .gst = c.GST_TAG_CAPTURING_SCENE_CAPTURE_TYPE, .tag = 0xA406, .kind = T_SHORT, .ser = mapSer(.scene), .de = mapDe(.scene) },
    .{ .gst = c.GST_TAG_CAPTURING_GAIN_ADJUSTMENT, .tag = 0xA407, .kind = T_SHORT, .ser = mapSer(.gain), .de = mapDe(.gain) },
    .{ .gst = c.GST_TAG_CAPTURING_CONTRAST, .tag = 0xA408, .kind = T_SHORT, .ser = mapSer(.contrast), .de = mapDe(.contrast) },
    .{ .gst = c.GST_TAG_CAPTURING_SATURATION, .tag = 0xA409, .kind = T_SHORT, .ser = mapSer(.saturation), .de = mapDe(.saturation) },
    .{ .gst = c.GST_TAG_CAPTURING_SHARPNESS, .tag = 0xA40A, .kind = T_SHORT, .ser = mapSer(.sharpness), .de = mapDe(.sharpness) },
};

const GPS = [_]Match{
    .{ .gst = c.GST_TAG_GEO_LOCATION_LATITUDE, .tag = GPS_LATITUDE, .kind = T_RATIONAL, .ref = GPS_LATITUDE_REF, .ser = serCoordinate, .de = deCoordinate },
    .{ .gst = c.GST_TAG_GEO_LOCATION_LONGITUDE, .tag = GPS_LONGITUDE, .kind = T_RATIONAL, .ref = GPS_LONGITUDE_REF, .ser = serCoordinate, .de = deCoordinate },
    .{ .gst = c.GST_TAG_GEO_LOCATION_ELEVATION, .tag = GPS_ALTITUDE, .kind = T_RATIONAL, .ref = GPS_ALTITUDE_REF, .ser = serElevation, .de = deElevation },
    .{ .gst = c.GST_TAG_GEO_LOCATION_MOVEMENT_SPEED, .tag = GPS_SPEED, .kind = T_RATIONAL, .ref = GPS_SPEED_REF, .ser = serSpeed, .de = deSpeed },
    .{ .gst = c.GST_TAG_GEO_LOCATION_MOVEMENT_DIRECTION, .tag = GPS_TRACK, .kind = T_RATIONAL, .ref = GPS_TRACK_REF, .ser = serDirection, .de = deDirection },
    .{ .gst = c.GST_TAG_GEO_LOCATION_CAPTURE_DIRECTION, .tag = GPS_IMAGE_DIRECTION, .kind = T_RATIONAL, .ref = GPS_IMAGE_DIRECTION_REF, .ser = serDirection, .de = deDirection },
    .{ .gst = c.GST_TAG_GEO_LOCATION_HORIZONTAL_ERROR, .tag = GPS_HORIZONTAL_ERROR, .kind = T_RATIONAL },
};

fn read16(order: c_int, p: [*c]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], if (order == LE) .little else .big);
}

fn read32(order: c_int, p: [*c]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], if (order == LE) .little else .big);
}

fn get16(r: *c.GstByteReader, order: c_int, v: *u16) bool {
    return (if (order == LE) c.gst_byte_reader_get_uint16_le(r, v) else c.gst_byte_reader_get_uint16_be(r, v)) != 0;
}

fn get32(r: *c.GstByteReader, order: c_int, v: *u32) bool {
    return (if (order == LE) c.gst_byte_reader_get_uint32_le(r, v) else c.gst_byte_reader_get_uint32_be(r, v)) != 0;
}

fn geti32(r: *c.GstByteReader, order: c_int, v: *i32) bool {
    return (if (order == LE) c.gst_byte_reader_get_int32_le(r, v) else c.gst_byte_reader_get_int32_be(r, v)) != 0;
}

fn peek16(r: *c.GstByteReader, order: c_int, v: *u16) bool {
    return (if (order == LE) c.gst_byte_reader_peek_uint16_le(r, v) else c.gst_byte_reader_peek_uint16_be(r, v)) != 0;
}

fn peek32(r: *c.GstByteReader, order: c_int, v: *u32) bool {
    return (if (order == LE) c.gst_byte_reader_peek_uint32_le(r, v) else c.gst_byte_reader_peek_uint32_be(r, v)) != 0;
}

fn put16(w: *c.GstByteWriter, order: c_int, v: u16) bool {
    return (if (order == LE) c.gst_byte_writer_put_uint16_le(w, v) else c.gst_byte_writer_put_uint16_be(w, v)) != 0;
}

fn put32(w: *c.GstByteWriter, order: c_int, v: u32) bool {
    return (if (order == LE) c.gst_byte_writer_put_uint32_le(w, v) else c.gst_byte_writer_put_uint32_be(w, v)) != 0;
}

fn puti32(w: *c.GstByteWriter, order: c_int, v: i32) bool {
    return (if (order == LE) c.gst_byte_writer_put_int32_le(w, v) else c.gst_byte_writer_put_int32_be(w, v)) != 0;
}

fn checkOrder(order: c_int) c_int {
    return if (order != LE and order != BE) c.G_BYTE_ORDER else order;
}

fn writerInit(w: *Writer, order: c_int) void {
    tags.gst_tag_register_musicbrainz_tags();
    c.gst_byte_writer_init(&w.tags);
    c.gst_byte_writer_init(&w.data);
    w.order = checkOrder(order);
    w.total = 0;
}

fn writerTake(w: *Writer) [*c]c.GstBuffer {
    const head = c.gst_byte_writer_reset_and_get_buffer(&w.tags);
    const data = c.gst_byte_writer_reset_and_get_buffer(&w.data);
    return c.gst_buffer_append(head, data);
}

fn dataSize(w: *Writer) u32 {
    return c.gst_byte_writer_get_size(&w.data);
}

fn header(w: *Writer, tag: u16, kind: u16, count: u32, offset: u32, raw: ?*const u32) void {
    var ok = put16(&w.tags, w.order, tag);
    ok = put16(&w.tags, w.order, kind) and ok;
    ok = put32(&w.tags, w.order, count) and ok;
    if (raw) |r| {
        ok = c.gst_byte_writer_put_data(&w.tags, @ptrCast(r), 4) != 0 and ok;
    } else ok = put32(&w.tags, w.order, offset) and ok;
    w.total += 1;
}

fn rationalData(w: *Writer, n: u32, d: u32) void {
    _ = put32(&w.data, w.order, n);
    _ = put32(&w.data, w.order, d);
}

fn rationalTag(w: *Writer, tag: u16, n: u32, d: u32) void {
    header(w, tag, T_RATIONAL, 1, dataSize(w), null);
    rationalData(w, n, d);
}

fn signedRationalTag(w: *Writer, tag: u16, n: i32, d: i32) void {
    header(w, tag, T_SRATIONAL, 1, dataSize(w), null);
    _ = puti32(&w.data, w.order, n);
    _ = puti32(&w.data, w.order, d);
}

fn rationalFromDouble(w: *Writer, tag: u16, value: f64) void {
    var n: c.gint = 0;
    var d: c.gint = 0;
    c.gst_util_double_to_fraction(value, &n, &d);
    rationalTag(w, tag, @bitCast(n), @bitCast(d));
}

fn signedRationalFromDouble(w: *Writer, tag: u16, value: f64) void {
    var n: c.gint = 0;
    var d: c.gint = 0;
    c.gst_util_double_to_fraction(value, &n, &d);
    signedRationalTag(w, tag, n, d);
}

fn byteTag(w: *Writer, tag: u16, value: u8) void {
    var raw: u32 = 0;
    std.mem.asBytes(&raw)[0] = value;
    header(w, tag, T_BYTE, 1, raw, &raw);
}

fn shortTag(w: *Writer, tag: u16, value: u16) void {
    var raw: u32 = 0;
    std.mem.writeInt(u16, std.mem.asBytes(&raw)[0..2], value, if (w.order == LE) .little else .big);
    header(w, tag, T_SHORT, 1, raw, &raw);
}

fn longTag(w: *Writer, tag: u16, value: u32) void {
    var raw: u32 = 0;
    std.mem.writeInt(u32, std.mem.asBytes(&raw), value, if (w.order == LE) .little else .big);
    header(w, tag, T_LONG, 1, raw, &raw);
}

fn undefinedTag(w: *Writer, tag: u16, data: [*c]const u8, size: usize) void {
    if (size > 4) {
        header(w, tag, T_UNDEFINED, @intCast(size), dataSize(w), null);
        _ = c.gst_byte_writer_put_data(&w.data, data, @intCast(size));
    } else {
        var raw: u32 = 0;
        @memcpy(std.mem.asBytes(&raw)[0..size], data[0..size]);
        header(w, tag, T_UNDEFINED, @intCast(size), raw, &raw);
    }
}

fn isAscii(s: [*c]const u8, len: *usize) bool {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {
        if (s[n] & 0x80 != 0) return false;
    }
    len.* = n;
    return true;
}

fn asciiTag(w: *Writer, tag: u16, s: [*c]const u8) void {
    var size: usize = 0;
    var err: [*c]c.GError = null;
    const ascii: [*c]u8 = if (isAscii(s, &size)) c.g_strndup(s, size) else c.g_convert(s, -1, "latin1", "utf8", null, &size, &err);
    if (err != null) {
        c.g_error_free(err);
        c.g_free(ascii);
        return;
    }
    size += 1;
    if (size > 4) {
        header(w, tag, T_ASCII, @intCast(size), dataSize(w), null);
        _ = c.gst_byte_writer_put_string_utf8(&w.data, ascii);
    } else {
        var raw: u32 = 0;
        @memcpy(std.mem.asBytes(&raw)[0..size], ascii[0..size]);
        header(w, tag, T_ASCII, @intCast(size), raw, &raw);
    }
    c.g_free(ascii);
}

fn asciiFromList(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    if (c.gst_tag_list_get_tag_size(list, m.gst) != 1) return;
    const value = c.gst_tag_list_get_value_index(list, m.gst, 0);
    var s: [*c]u8 = null;
    var owned = false;
    if (value[0].g_type == c.G_TYPE_STRING) {
        s = @constCast(c.g_value_get_string(value));
    } else if (value[0].g_type == c.gst_date_time_get_type()) {
        const dt: ?*c.GstDateTime = @ptrCast(c.g_value_get_boxed(value));
        if (dt != null) {
            s = c.g_strdup_printf("%04d:%02d:%02d %02d:%02d:%02d", c.gst_date_time_get_year(dt), c.gst_date_time_get_month(dt), c.gst_date_time_get_day(dt), c.gst_date_time_get_hour(dt), c.gst_date_time_get_minute(dt), c.gst_date_time_get_second(dt));
            owned = true;
        }
    }
    if (s == null) return;
    asciiTag(w, m.tag, s);
    if (owned) c.g_free(s);
}

fn undefinedFromList(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    if (c.gst_tag_list_get_tag_size(list, m.gst) != 1) return;
    const value = c.gst_tag_list_get_value_index(list, m.gst, 0);
    var data: [*c]const u8 = null;
    var size: usize = 0;
    var buf: [*c]c.GstBuffer = null;
    var info: c.GstMapInfo = undefined;
    if (value[0].g_type == c.G_TYPE_STRING) {
        data = c.g_value_get_string(value);
        size = c.strlen(data);
    } else if (value[0].g_type == c.gst_sample_get_type()) {
        buf = c.gst_sample_get_buffer(@ptrCast(c.g_value_get_boxed(value)));
        if (c.gst_buffer_map(buf, &info, c.GST_MAP_READ) != 0) {
            data = info.data;
            size = info.size;
        }
    }
    if (size > 0) undefinedTag(w, m.tag, data, size);
    if (buf != null) c.gst_buffer_unmap(buf, &info);
}

fn rationalFromList(w: *Writer, list: [*c]const c.GstTagList, m: *const Match, signed: bool) void {
    if (c.gst_tag_list_get_tag_size(list, m.gst) != 1) return;
    const value = c.gst_tag_list_get_value_index(list, m.gst, 0);
    if (value[0].g_type == c.G_TYPE_DOUBLE) {
        const num = c.g_value_get_double(value);
        if (signed) signedRationalFromDouble(w, m.tag, num) else rationalFromDouble(w, m.tag, num);
    } else if (value[0].g_type == c.gst_fraction_get_type()) {
        const n = c.gst_value_get_fraction_numerator(value);
        const d = c.gst_value_get_fraction_denominator(value);
        if (signed) signedRationalTag(w, m.tag, n, d) else rationalTag(w, m.tag, @bitCast(n), @bitCast(d));
    }
}

fn integerFromList(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    if (c.gst_tag_list_get_tag_size(list, m.gst) != 1) return;
    const value = c.gst_tag_list_get_value_index(list, m.gst, 0);
    var num: u32 = 0;
    if (value[0].g_type == c.G_TYPE_INT) {
        num = @bitCast(c.g_value_get_int(value));
    } else if (value[0].g_type == c.G_TYPE_DOUBLE) {
        num = @bitCast(@as(c.gint, @intFromFloat(c.g_value_get_double(value))));
    }
    switch (m.kind) {
        T_LONG => longTag(w, m.tag, num),
        T_SHORT => shortTag(w, m.tag, @truncate(num)),
        else => {},
    }
}

fn fromList(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    if (m.ser) |f| return f(w, list, m);
    switch (m.kind) {
        T_ASCII => asciiFromList(w, list, m),
        T_UNDEFINED => undefinedFromList(w, list, m),
        T_RATIONAL => rationalFromList(w, list, m, false),
        T_SRATIONAL => rationalFromList(w, list, m, true),
        T_LONG, T_SHORT => integerFromList(w, list, m),
        else => {},
    }
}

fn rewriteOffsets(w: *c.GstByteWriter, order: c_int, offset: u32, count: c.gint, inner: ?*c.GstByteWriter) void {
    const r: *c.GstByteReader = &w.parent;
    var num = count;
    if (num == -1) {
        var aux: u16 = 0xffff;
        _ = get16(r, order, &aux);
        if (aux == 0xffff) return;
        num = aux;
    }
    var i: c.gint = 0;
    while (i < num) : (i += 1) {
        var tag: u16 = 0;
        var kind: u16 = 0;
        var n: u32 = 0;
        if (!get16(r, order, &tag) or !get16(r, order, &kind) or !get32(r, order, &n)) break;
        const size: i64 = switch (kind) {
            T_BYTE, T_ASCII, T_UNDEFINED => n,
            T_SHORT => @as(i64, n) * 2,
            T_LONG, T_SLONG => @as(i64, n) * 4,
            T_RATIONAL, T_SRATIONAL => @as(i64, n) * 8,
            else => unreachable,
        };
        if (size > 4 or tag == IFD_GPS or tag == IFD_EXIF) {
            var cur: u32 = 0;
            if (peek32(r, order, &cur)) _ = put32(w, order, cur +% offset);
            if ((tag == IFD_GPS or tag == IFD_EXIF) and inner != null) {
                if (c.gst_byte_writer_set_pos(inner.?, cur) == 0) continue;
                rewriteOffsets(inner.?, order, offset, -1, null);
            }
        } else _ = c.gst_byte_reader_skip(r, 4);
    }
}

fn hasIfdTags(list: [*c]const c.GstTagList, map: []const Match) bool {
    for (map) |m| {
        if (m.gst == null) {
            if (m.tag == IFD_GPS and hasIfdTags(list, &GPS)) return true;
            if (m.tag == IFD_EXIF and hasIfdTags(list, &EXIF)) return true;
            continue;
        }
        if (c.gst_tag_list_get_value_index(list, m.gst, 0) != null) return true;
    }
    return false;
}

fn writeIfd(list: [*c]const c.GstTagList, order: c_int, base: u32, map: []const Match) [*c]c.GstBuffer {
    if (!hasIfdTags(list, map)) return null;
    var w: Writer = undefined;
    writerInit(&w, order);
    var ok = c.gst_byte_writer_put_uint16_le(&w.tags, 0) != 0;
    for (map) |*m| {
        if (m.gst == null) {
            var inner_map: ?[]const Match = null;
            if (m.tag == IFD_GPS) {
                inner_map = &GPS;
            } else if (m.tag == IFD_EXIF) {
                inner_map = &EXIF;
            } else if (m.tag == VERSION) {
                undefinedTag(&w, VERSION, "0230", 4);
            } else if (m.tag == FLASHPIX_VERSION) {
                undefinedTag(&w, FLASHPIX_VERSION, "0100", 4);
            }
            if (inner_map) |im| {
                const inner = writeIfd(list, order, dataSize(&w), im);
                if (inner != null) {
                    header(&w, m.tag, T_LONG, 1, dataSize(&w), null);
                    var info: c.GstMapInfo = undefined;
                    if (c.gst_buffer_map(inner, &info, c.GST_MAP_READ) != 0) {
                        ok = c.gst_byte_writer_put_data(&w.data, info.data, @intCast(info.size)) != 0 and ok;
                        c.gst_buffer_unmap(inner, &info);
                    } else ok = false;
                    c.gst_buffer_unref(inner);
                }
            }
            continue;
        }
        if (c.gst_tag_list_get_value_index(list, m.gst, 0) == null) continue;
        fromList(&w, list, m);
    }
    ok = c.gst_byte_writer_put_uint32_le(&w.tags, 0) != 0 and ok;
    _ = c.gst_byte_writer_set_pos(&w.tags, 0);
    ok = put16(&w.tags, w.order, @truncate(w.total)) and ok;
    rewriteOffsets(&w.tags, w.order, base +% c.gst_byte_writer_get_size(&w.tags), @intCast(w.total), &w.data);
    if (!ok) {
        c.gst_buffer_unref(writerTake(&w));
        return null;
    }
    return writerTake(&w);
}

fn mapSer(comptime k: ev.Kind) Ser {
    return struct {
        fn f(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
            var s: [*c]u8 = null;
            if (c.gst_tag_list_get_string_index(list, m.gst, 0, &s) == 0) return;
            const v = ev.to(k, s);
            c.g_free(s);
            if (v == -1) return;
            switch (m.kind) {
                T_SHORT => shortTag(w, m.tag, @truncate(@as(u32, @bitCast(v)))),
                T_LONG => longTag(w, m.tag, @bitCast(v)),
                T_UNDEFINED => {
                    const b: u8 = @truncate(@as(u32, @bitCast(v)));
                    undefinedTag(w, m.tag, &b, 1);
                },
                else => unreachable,
            }
        }
    }.f;
}

fn mapDe(comptime k: ev.Kind) De {
    return struct {
        fn f(er: *Reader, _: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
            if (d.count != 1) return 0;
            const v: c.gint = switch (d.kind) {
                T_SHORT => read16(er.order, d.raw),
                T_UNDEFINED => d.raw[0],
                else => return 0,
            };
            const s = ev.from(k, v) orelse return 0;
            c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, s, NONE);
            return 0;
        }
    }.f;
}

fn readerInit(er: *Reader, order: c_int, buf: [*c]c.GstBuffer, base: u32) void {
    tags.gst_tag_register_musicbrainz_tags();
    er.list = c.gst_tag_list_new_empty();
    er.buffer = buf;
    er.base = base;
    er.order = checkOrder(order);
    er.pending = null;
}

fn readerReset(er: *Reader, take: bool) [*c]c.GstTagList {
    var walk = er.pending;
    while (walk) |n| : (walk = n.next) c.g_free(n.data);
    c.g_slist_free(er.pending);
    var ret: [*c]c.GstTagList = null;
    if (take) {
        ret = er.list;
        er.list = null;
    }
    if (er.list != null) c.gst_mini_object_unref(@ptrCast(er.list));
    return ret;
}

fn pendingTag(er: *Reader, tag: u16) ?*Data {
    var walk = er.pending;
    while (walk) |n| : (walk = n.next) {
        const d: *Data = @ptrCast(@alignCast(n.data));
        if (d.tag == tag) return d;
    }
    return null;
}

fn findReverse(tag: u16, map: []const Match) ?usize {
    for (map, 0..) |m, i| {
        if (tag == m.tag or tag == m.ref) return i;
    }
    return null;
}

fn parseHeader(r: *c.GstByteReader, order: c_int, d: *Data) bool {
    if (!get16(r, order, &d.tag) or !get16(r, order, &d.kind) or !get32(r, order, &d.count) or c.gst_byte_reader_get_data(r, 4, &d.raw) == 0) return false;
    d.offset = read32(order, d.raw);
    return true;
}

fn mappedSlice(er: *Reader, offset: u32, count: u32, info: *c.GstMapInfo) ?u32 {
    if (offset < er.base) return null;
    const real = offset - er.base;
    if (c.gst_buffer_map(er.buffer, info, c.GST_MAP_READ) == 0) return null;
    if (real >= info.size or info.size - real < count) {
        c.gst_buffer_unmap(er.buffer, info);
        return null;
    }
    return real;
}

fn parseAscii(er: *Reader, m: *const Match, count: u32, offset: u32, raw: [*c]const u8) void {
    var s: [*c]u8 = undefined;
    if (count > 4) {
        var info: c.GstMapInfo = undefined;
        const real = mappedSlice(er, offset, count, &info) orelse return;
        s = c.g_strndup(@ptrCast(info.data + real), count);
        c.gst_buffer_unmap(er.buffer, &info);
    } else s = c.g_strndup(raw, count);
    var utf: [*c]u8 = s;
    if (c.g_utf8_validate(s, -1, null) == 0) {
        var err: [*c]c.GError = null;
        utf = c.g_convert(s, count, "utf8", "latin1", null, null, &err);
        c.g_free(s);
        if (err != null) {
            c.g_error_free(err);
            return;
        }
    }
    const t = c.gst_tag_get_type(m.gst);
    if (t == c.gst_date_time_get_type()) {
        var year: c_int = 0;
        var month: c_int = 1;
        var day: c_int = 1;
        var hour: c_int = 0;
        var minute: c_int = 0;
        var second: c_int = 0;
        if (c.sscanf(utf, "%04d:%02d:%02d %02d:%02d:%02d", &year, &month, &day, &hour, &minute, &second) > 0) {
            const d = c.gst_date_time_new_local_time(year, month, day, hour, minute, @floatFromInt(second));
            if (d != null) {
                c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, d, NONE);
                c.gst_date_time_unref(d);
            }
        }
    } else if (t == c.G_TYPE_STRING) {
        if (utf[0] != 0) c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, utf, NONE);
    }
    c.g_free(utf);
}

fn parseShort(er: *Reader, m: *const Match, count: u32, raw: [*c]const u8) void {
    if (count > 1) return;
    const v = read16(er.order, raw);
    const t = c.gst_tag_get_type(m.gst);
    if (t == c.G_TYPE_INT) {
        c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, @as(c_int, v), NONE);
    } else if (t == c.G_TYPE_DOUBLE) {
        c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, @as(f64, @floatFromInt(v)), NONE);
    }
}

fn parseLong(er: *Reader, m: *const Match, count: u32, offset: u32) void {
    if (count > 1) return;
    if (c.gst_tag_get_type(m.gst) == c.G_TYPE_INT) c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, @as(c.guint, offset), NONE);
}

fn parseUndefined(er: *Reader, m: *const Match, count: u32, offset: u32, raw: [*c]const u8) void {
    var data: [*c]u8 = undefined;
    if (count > 4) {
        var info: c.GstMapInfo = undefined;
        const real = mappedSlice(er, offset, count, &info) orelse return;
        data = @ptrCast(c.g_malloc(@as(usize, count) + 1));
        @memcpy(data[0..count], info.data[real .. real + count]);
        data[count] = 0;
        c.gst_buffer_unmap(er.buffer, &info);
    } else {
        data = @ptrCast(c.g_malloc(@as(usize, count) + 1));
        @memcpy(data[0..count], raw[0..count]);
        data[count] = 0;
    }
    const t = c.gst_tag_get_type(m.gst);
    if (t == c.gst_sample_get_type()) {
        const buf = c.gst_buffer_new_wrapped(data, count);
        data = null;
        const sample = c.gst_sample_new(buf, null, null, null);
        c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_APPEND, m.gst, sample, NONE);
        c.gst_mini_object_unref(@ptrCast(@alignCast(sample)));
        c.gst_mini_object_unref(@ptrCast(@alignCast(buf)));
    } else if (t == c.G_TYPE_STRING) {
        if (data[0] != 0) c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, data, NONE);
    }
    c.g_free(data);
}

fn readRational(er: *Reader, offset: u32, signed: bool, out_n: *i32, out_d: *i32) bool {
    if (offset < er.base) return false;
    const real = offset - er.base;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(er.buffer, &info, c.GST_MAP_READ) == 0) return false;
    defer c.gst_buffer_unmap(er.buffer, &info);
    if (real >= info.size) return false;
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, info.data, @intCast(info.size));
    if (c.gst_byte_reader_set_pos(&r, real) == 0) return false;
    var n: i32 = 0;
    var d: i32 = 0;
    if (!signed) {
        var un: u32 = 0;
        var ud: u32 = 0;
        if (!get32(&r, er.order, &un) or !get32(&r, er.order, &ud)) return false;
        n = @bitCast(un);
        d = @bitCast(ud);
    } else if (!geti32(&r, er.order, &n) or !geti32(&r, er.order, &d)) return false;
    if (n == std.math.minInt(i32) or d == std.math.minInt(i32) or d == 0) return false;
    out_n.* = n;
    out_d.* = d;
    return true;
}

fn parseRational(er: *Reader, gst_tag: [*c]const u8, offset: u32, mult: f64, signed: bool) void {
    var n: i32 = 0;
    var d: i32 = 1;
    if (!readRational(er, offset, signed, &n, &d)) return;
    const t = c.gst_tag_get_type(gst_tag);
    if (t == c.G_TYPE_DOUBLE) {
        var v: f64 = 0;
        c.gst_util_fraction_to_double(n, d, &v);
        v *= mult;
        c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, gst_tag, v, NONE);
    } else if (t == c.gst_fraction_get_type()) {
        var f = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&f, t);
        c.gst_value_set_fraction(&f, @intFromFloat(@as(f64, @floatFromInt(n)) * mult), d);
        c.gst_tag_list_add_value(er.list, c.GST_TAG_MERGE_REPLACE, gst_tag, &f);
        c.g_value_unset(&f);
    }
}

fn parseIfd(er: *Reader, at: u32, map: []const Match) bool {
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(er.buffer, &info, c.GST_MAP_READ) == 0) return false;
    defer c.gst_buffer_unmap(er.buffer, &info);
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, info.data, @intCast(info.size));
    if (c.gst_byte_reader_set_pos(&r, at) == 0) return false;
    var entries: u16 = 0;
    if (!get16(&r, er.order, &entries)) return false;
    var i: u16 = 0;
    while (i < entries) : (i +%= 1) {
        var d = Data{};
        if (!parseHeader(&r, er.order, &d)) return false;
        const idx = findReverse(d.tag, map) orelse continue;
        const m = &map[idx];
        if (d.tag == IFD_GPS or d.tag == IFD_EXIF) {
            if (d.offset < er.base) continue;
            _ = parseIfd(er, d.offset - er.base, if (d.tag == IFD_GPS) &GPS else &EXIF);
            continue;
        }
        if (d.tag == VERSION or d.tag == FLASHPIX_VERSION) continue;
        if (m.de) |f| {
            i +%= @truncate(@as(u32, @bitCast(f(er, &r, m, &d))));
            continue;
        }
        switch (d.kind) {
            T_ASCII => parseAscii(er, m, d.count, d.offset, d.raw),
            T_RATIONAL => parseRational(er, m.gst, d.offset, 1, false),
            T_SRATIONAL => parseRational(er, m.gst, d.offset, 1, true),
            T_UNDEFINED => parseUndefined(er, m, d.count, d.offset, d.raw),
            T_LONG => parseLong(er, m, d.count, d.offset),
            T_SHORT => parseShort(er, m, d.count, d.raw),
            else => {},
        }
    }
    var walk = er.pending;
    while (walk) |n| : (walk = n.next) {
        const p: *Data = @ptrCast(@alignCast(n.data));
        switch (p.tag) {
            XRESOLUTION => parseRational(er, c.GST_TAG_IMAGE_HORIZONTAL_PPI, p.offset, 1, false),
            YRESOLUTION => parseRational(er, c.GST_TAG_IMAGE_VERTICAL_PPI, p.offset, 1, false),
            else => {},
        }
    }
    return true;
}

fn dePending(er: *Reader, _: *c.GstByteReader, _: *const Match, d: *Data) c.gint {
    const copy: *Data = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Data))));
    copy.* = d.*;
    er.pending = c.g_slist_prepend(er.pending, copy);
    return 0;
}

fn deResolution(er: *Reader, _: *c.GstByteReader, _: *const Match, d: *Data) c.gint {
    const mult: f64 = switch (read16(er.order, d.raw)) {
        2 => 1,
        3 => 1.0 / 2.54,
        else => return 0,
    };
    if (pendingTag(er, XRESOLUTION)) |x| parseRational(er, c.GST_TAG_IMAGE_HORIZONTAL_PPI, x.offset, mult, false);
    if (pendingTag(er, YRESOLUTION)) |y| parseRational(er, c.GST_TAG_IMAGE_VERTICAL_PPI, y.offset, mult, false);
    return 0;
}

fn serCoordinate(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var value: f64 = 0;
    if (c.gst_tag_list_get_double(list, m.gst, &value) == 0) return;
    const lat = m.tag == GPS_LATITUDE;
    if (value >= 0) {
        asciiTag(w, m.ref, if (lat) "N" else "E");
    } else {
        value *= -1;
        asciiTag(w, m.ref, if (lat) "S" else "W");
    }
    const degrees: u32 = @intFromFloat(value);
    value -= @floatFromInt(degrees);
    const minutes: u32 = @intFromFloat(value * 60);
    value = (value * 60) - @as(f64, @floatFromInt(minutes));
    const den: u32 = 10000000;
    const num: u32 = @intFromFloat(value * 60 * @as(f64, @floatFromInt(den)));
    header(w, m.tag, T_RATIONAL, 3, dataSize(w), null);
    rationalData(w, degrees, 1);
    rationalData(w, minutes, 1);
    rationalData(w, num, den);
}

fn deCoordinate(er: *Reader, r: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    if (m.ref != d.tag) return 0;
    const mult: f64 = switch (d.raw[0]) {
        'N', 'E' => 1,
        'S', 'W' => -1,
        else => return 0,
    };
    var next = Data{};
    if (!peek16(r, er.order, &next.tag)) return 0;
    if (m.tag != next.tag) return 0;
    if (!parseHeader(r, er.order, &next)) return -1;
    if (next.kind != T_RATIONAL or next.count != 3 or next.offset < er.base) return 1;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(er.buffer, &info, c.GST_MAP_READ) == 0) return 1;
    var fr: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&fr, info.data, @intCast(info.size));
    var v = [6]u32{ 0, 1, 0, 1, 0, 1 };
    var ok = c.gst_byte_reader_set_pos(&fr, next.offset - er.base) != 0;
    for (&v) |*x| {
        if (!ok) break;
        ok = get32(&fr, er.order, x);
    }
    c.gst_buffer_unmap(er.buffer, &info);
    if (!ok) return 1;
    var degrees: f64 = 0;
    var minutes: f64 = 0;
    var seconds: f64 = 0;
    c.gst_util_fraction_to_double(@bitCast(v[0]), @bitCast(v[1]), &degrees);
    c.gst_util_fraction_to_double(@bitCast(v[2]), @bitCast(v[3]), &minutes);
    c.gst_util_fraction_to_double(@bitCast(v[4]), @bitCast(v[5]), &seconds);
    minutes += seconds / 60;
    degrees += minutes / 60;
    degrees *= mult;
    c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, m.gst, degrees, NONE);
    return 1;
}

fn follow(er: *Reader, r: *c.GstByteReader, m: *const Match, d: *Data, mult: f64) c.gint {
    var next = Data{};
    if (m.ref != d.tag and d.tag == m.tag) next = d.*;
    var ret: c.gint = 0;
    if (next.tag == 0) {
        if (!peek16(r, er.order, &next.tag)) return ret;
        if (m.tag != next.tag) return ret;
        if (!parseHeader(r, er.order, &next)) return -1;
        ret = 1;
    }
    if (next.kind != T_RATIONAL or next.count != 1) return ret;
    parseRational(er, m.gst, next.offset, mult, false);
    return ret;
}

fn serDirection(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var value: f64 = 0;
    if (c.gst_tag_list_get_double(list, m.gst, &value) == 0) return;
    asciiTag(w, m.ref, "T");
    rationalFromDouble(w, m.tag, value);
}

fn deDirection(er: *Reader, r: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    if (m.ref == d.tag and d.raw[0] != 'T') return 0;
    return follow(er, r, m, d, 1);
}

fn serElevation(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var value: f64 = 0;
    if (c.gst_tag_list_get_double(list, m.gst, &value) == 0) return;
    byteTag(w, m.ref, if (value >= 0) 0 else 1);
    if (value < 0) value *= -1;
    rationalFromDouble(w, m.tag, value);
}

fn deElevation(er: *Reader, r: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    var mult: f64 = 1;
    if (m.ref == d.tag) {
        switch (d.raw[0]) {
            0 => {},
            1 => mult = -1,
            else => return 0,
        }
    }
    return follow(er, r, m, d, mult);
}

fn serSpeed(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var value: f64 = 0;
    if (c.gst_tag_list_get_double(list, m.gst, &value) == 0) return;
    asciiTag(w, m.ref, "K");
    rationalFromDouble(w, m.tag, value * 3.6);
}

fn deSpeed(er: *Reader, r: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    var mult: f64 = 1.0 / 3.6;
    if (m.ref == d.tag) {
        mult = switch (d.raw[0]) {
            'K' => 1.0 / 3.6,
            'M' => 0.44704,
            'N' => 0.514444,
            else => return 0,
        };
    }
    return follow(er, r, m, d, mult);
}

fn serShutter(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    const value = c.gst_tag_list_get_value_index(list, m.gst, 0);
    if (value == null) return;
    var num: f64 = 0;
    c.gst_util_fraction_to_double(c.gst_value_get_fraction_numerator(value), c.gst_value_get_fraction_denominator(value), &num);
    signedRationalFromDouble(w, m.tag, -log2(num));
}

fn deShutter(er: *Reader, _: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    var n: i32 = 0;
    var den: i32 = 0;
    if (!readRational(er, d.offset, true, &n, &den)) return 0;
    var v: f64 = 0;
    c.gst_util_fraction_to_double(n, den, &v);
    v = pow(2, -v);
    c.gst_util_double_to_fraction(v, &n, &den);
    var f = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&f, c.gst_fraction_get_type());
    c.gst_value_set_fraction(&f, n, den);
    c.gst_tag_list_add_value(er.list, c.GST_TAG_MERGE_KEEP, m.gst, &f);
    c.g_value_unset(&f);
    return 0;
}

fn serAperture(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var num: f64 = 0;
    if (c.gst_tag_list_get_double_index(list, m.gst, 0, &num) == 0) return;
    rationalFromDouble(w, m.tag, 2 * log2(num));
}

fn deAperture(er: *Reader, _: *c.GstByteReader, m: *const Match, d: *Data) c.gint {
    var n: i32 = 0;
    var den: i32 = 0;
    if (!readRational(er, d.offset, false, &n, &den)) return 0;
    var v: f64 = 0;
    c.gst_util_fraction_to_double(n, den, &v);
    c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_KEEP, m.gst, pow(2, v / 2), NONE);
    return 0;
}

fn serSensitivity(w: *Writer, _: [*c]const c.GstTagList, m: *const Match) void {
    shortTag(w, m.tag, 3);
}

fn deSensitivity(er: *Reader, _: *c.GstByteReader, _: *const Match, d: *Data) c.gint {
    if (read16(er.order, d.raw) != 3) return 0;
    const s = pendingTag(er, PHOTOGRAPHIC_SENSITIVITY) orelse return 0;
    c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_KEEP, c.GST_TAG_CAPTURING_ISO_SPEED, @as(c.guint, read16(er.order, s.raw)), NONE);
    return 0;
}

fn serFlash(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var fired: c.gboolean = 0;
    if (c.gst_tag_list_get_boolean_index(list, m.gst, 0, &fired) == 0) return;
    var v: u16 = if (fired != 0) 1 else 0;
    var mode_str: [*c]const u8 = null;
    if (c.gst_tag_list_peek_string_index(list, c.GST_TAG_CAPTURING_FLASH_MODE, 0, &mode_str) != 0) {
        var mode: u16 = 0;
        if (c.strcmp(mode_str, "auto") == 0) {
            mode = 3;
        } else if (c.strcmp(mode_str, "always") == 0) {
            mode = 1;
        } else if (c.strcmp(mode_str, "never") == 0) mode = 2;
        v |= mode << 3;
    }
    shortTag(w, m.tag, v);
}

fn deFlash(er: *Reader, _: *c.GstByteReader, _: *const Match, d: *Data) c.gint {
    const v = read16(er.order, d.raw);
    c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_CAPTURING_FLASH_FIRED, @as(c.gboolean, @intFromBool(v & 1 != 0)), NONE);
    const mode: ?[*:0]const u8 = switch ((v >> 3) & 3) {
        1 => "always",
        2 => "never",
        3 => "auto",
        else => null,
    };
    if (mode) |s| c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_CAPTURING_FLASH_MODE, s, NONE);
    return 0;
}

fn serSceneType(w: *Writer, list: [*c]const c.GstTagList, m: *const Match) void {
    var s: [*c]const u8 = null;
    var v: u8 = 0;
    if (c.gst_tag_list_peek_string_index(list, c.GST_TAG_CAPTURING_SOURCE, 0, &s) != 0 and c.strcmp(s, "dsc") == 0) v = 1;
    if (v != 0) undefinedTag(w, m.tag, &v, 1);
}

fn deSceneType(er: *Reader, _: *c.GstByteReader, _: *const Match, d: *Data) c.gint {
    if (d.raw[0] == 1) c.gst_tag_list_add(er.list, c.GST_TAG_MERGE_KEEP, c.GST_TAG_CAPTURING_SOURCE, "dsc", NONE);
    return 0;
}

pub export fn gst_tag_list_to_exif_buffer(list: [*c]const c.GstTagList, order: c.gint, base: c.guint32) [*c]c.GstBuffer {
    return writeIfd(list, order, base, &IFD0);
}

pub export fn gst_tag_list_to_exif_buffer_with_tiff_header(list: [*c]const c.GstTagList) [*c]c.GstBuffer {
    const ifd = gst_tag_list_to_exif_buffer(list, c.G_BYTE_ORDER, 8);
    if (ifd == null) return null;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(ifd, &info, c.GST_MAP_READ) == 0) {
        c.gst_buffer_unref(ifd);
        return null;
    }
    var w: c.GstByteWriter = undefined;
    c.gst_byte_writer_init_with_size(&w, @intCast(info.size + 8), 0);
    var ok = put16(&w, c.G_BYTE_ORDER, if (c.G_BYTE_ORDER == LE) 0x4949 else 0x4D4D);
    ok = put16(&w, c.G_BYTE_ORDER, 42) and ok;
    ok = put32(&w, c.G_BYTE_ORDER, 8) and ok;
    _ = c.gst_byte_writer_put_data(&w, info.data, @intCast(info.size));
    c.gst_buffer_unmap(ifd, &info);
    c.gst_buffer_unref(ifd);
    var res = c.gst_byte_writer_reset_and_get_buffer(&w);
    if (!ok) {
        c.gst_buffer_unref(res);
        res = null;
    }
    return res;
}

pub export fn gst_tag_list_from_exif_buffer(buffer: [*c]c.GstBuffer, order: c.gint, base: c.guint32) [*c]c.GstTagList {
    if (!check.that(order == LE or order == BE, "gst_tag_list_from_exif_buffer", "byte_order == G_LITTLE_ENDIAN || byte_order == G_BIG_ENDIAN")) return null;
    var er: Reader = undefined;
    readerInit(&er, order, buffer, base);
    if (!parseIfd(&er, 0, &IFD0)) {
        _ = readerReset(&er, false);
        return null;
    }
    return readerReset(&er, true);
}

pub export fn gst_tag_list_from_exif_buffer_with_tiff_header(buffer: [*c]c.GstBuffer) [*c]c.GstTagList {
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buffer, &info, c.GST_MAP_READ) == 0) return null;
    defer c.gst_buffer_unmap(buffer, &info);
    var r: c.GstByteReader = undefined;
    c.gst_byte_reader_init(&r, info.data, @intCast(info.size));
    var endian: u16 = 0;
    var magic: u16 = 42;
    var offset: u32 = 0;
    if (c.gst_byte_reader_get_uint16_be(&r, &endian) == 0) return null;
    const order: c_int = switch (endian) {
        0x4949 => LE,
        0x4D4D => BE,
        else => return null,
    };
    if (!get16(&r, order, &magic) or !get32(&r, order, &offset)) return null;
    if (magic != 42) return null;
    const sub = c.gst_buffer_new_allocate(null, info.size - 6, null);
    var sinfo: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(sub, &sinfo, c.GST_MAP_WRITE) == 0) {
        c.gst_buffer_unref(sub);
        return null;
    }
    @memcpy(sinfo.data[0 .. info.size - 8], info.data[8..info.size]);
    c.gst_buffer_unmap(sub, &sinfo);
    const list = gst_tag_list_from_exif_buffer(sub, order, 8);
    c.gst_buffer_unref(sub);
    return list;
}
