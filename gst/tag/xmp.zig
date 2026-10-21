const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const tags = @import("tags.zig");
const exifval = @import("exifvalues.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const NONE = @as(?*anyopaque, null);

var schema_list = [_][*c]const u8{ "dc", "xap", "tiff", "exif", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt", null };

pub export fn gst_tag_xmp_list_schemas() [*c][*c]const u8 {
    return &schema_list;
}

const Kind = enum(c_int) { none = 0, simple, bag, seq, structure, compound };

const Serialize = *const fn ([*c]const c.GValue) [*c]u8;
const Deserialize = *const fn (*Tag, [*c]c.GstTagList, [*c]const u8, [*c]const u8, [*c]const u8, *?*c.GSList) void;

pub const Tag = struct {
    gst_tag: [*c]const u8,
    name: [*c]const u8,
    kind: Kind,
    supertype: Kind = .none,
    parse_type: [*c]const u8 = null,
    children: ?*c.GSList = null,
    serialize: ?Serialize = null,
    deserialize: ?Deserialize = null,
};

const Pending = struct {
    tag: *Tag,
    str: [*c]u8,
};

var schemas: ?*c.GHashTable = null;
var init_once = std.mem.zeroes(c.GOnce);

fn mergeMode(t: *Tag) c.GstTagMergeMode {
    return switch (t.kind) {
        .bag, .seq => c.GST_TAG_MERGE_APPEND,
        else => c.GST_TAG_MERGE_KEEP,
    };
}

fn typeName(k: Kind) [*c]const u8 {
    return switch (k) {
        .seq => "rdf:Seq",
        .bag => "rdf:Bag",
        else => blk: {
            c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", "../gst-libs/gst/tag/gstxmptag.c", @as(c_int, 198), "xmp_tag_type_get_name");
            break :blk "";
        },
    };
}

fn quarkKey(s: [*c]const u8) c.gpointer {
    return @ptrFromInt(@as(usize, c.g_quark_from_string(s)));
}

fn getSchema(name: [*c]const u8) ?*c.GHashTable {
    return @ptrCast(c.g_hash_table_lookup(schemas, quarkKey(name)));
}

fn create(gst_tag: [*c]const u8, name: [*c]const u8, kind: Kind, ser: ?Serialize, de: ?Deserialize) *Tag {
    const t: *Tag = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Tag))));
    t.* = .{ .gst_tag = gst_tag, .name = name, .kind = kind, .serialize = ser, .deserialize = de };
    return t;
}

fn createCompound(gst_tag: [*c]const u8, a: [*c]const u8, b: [*c]const u8, sa: Serialize, sb: Serialize, de: Deserialize) *Tag {
    const ta = create(gst_tag, a, .simple, sa, de);
    const tb = create(gst_tag, b, .simple, sb, de);
    const t = create(gst_tag, null, .compound, null, null);
    t.children = c.g_slist_prepend(t.children, tb);
    t.children = c.g_slist_prepend(t.children, ta);
    return t;
}

fn addMapping(schema: ?*c.GHashTable, t: *Tag) void {
    _ = c.g_hash_table_insert(schema, quarkKey(t.gst_tag), t);
}

fn simple(schema: ?*c.GHashTable, gst_tag: [*c]const u8, name: [*c]const u8, kind: Kind, ser: ?Serialize, de: ?Deserialize) void {
    addMapping(schema, create(gst_tag, name, kind, ser, de));
}

fn newSchema() ?*c.GHashTable {
    return c.g_hash_table_new(c.g_direct_hash, c.g_direct_equal);
}

fn addSchema(name: [*c]const u8, s: ?*c.GHashTable) void {
    _ = c.g_hash_table_insert(schemas, quarkKey(name), s);
}

fn initMap(_: c.gpointer) callconv(.c) c.gpointer {
    tags.gst_tag_register_musicbrainz_tags();
    schemas = c.g_hash_table_new(c.g_direct_hash, c.g_direct_equal);
    var s = newSchema();
    simple(s, c.GST_TAG_ARTIST, "dc:creator", .seq, null, null);
    simple(s, c.GST_TAG_COPYRIGHT, "dc:rights", .simple, null, null);
    simple(s, c.GST_TAG_DATE_TIME, "dc:date", .seq, null, null);
    simple(s, c.GST_TAG_DESCRIPTION, "dc:description", .simple, null, null);
    simple(s, c.GST_TAG_KEYWORDS, "dc:subject", .bag, null, null);
    simple(s, c.GST_TAG_TITLE, "dc:title", .simple, null, null);
    simple(s, c.GST_TAG_VIDEO_CODEC, "dc:format", .simple, null, null);
    addSchema("dc", s);
    s = newSchema();
    simple(s, c.GST_TAG_USER_RATING, "xmp:Rating", .simple, null, deRating);
    addSchema("xap", s);
    s = newSchema();
    simple(s, c.GST_TAG_DEVICE_MANUFACTURER, "tiff:Make", .simple, null, null);
    simple(s, c.GST_TAG_DEVICE_MODEL, "tiff:Model", .simple, null, null);
    simple(s, c.GST_TAG_APPLICATION_NAME, "tiff:Software", .simple, null, null);
    simple(s, c.GST_TAG_IMAGE_ORIENTATION, "tiff:Orientation", .simple, serOrientation, deOrientation);
    addSchema("tiff", s);
    s = newSchema();
    simple(s, c.GST_TAG_DATE_TIME, "exif:DateTimeOriginal", .simple, null, null);
    simple(s, c.GST_TAG_GEO_LOCATION_LATITUDE, "exif:GPSLatitude", .simple, serLatitude, deLatitude);
    simple(s, c.GST_TAG_GEO_LOCATION_LONGITUDE, "exif:GPSLongitude", .simple, serLongitude, deLongitude);
    simple(s, c.GST_TAG_CAPTURING_EXPOSURE_COMPENSATION, "exif:ExposureBiasValue", .simple, null, null);
    addMapping(s, createCompound(c.GST_TAG_GEO_LOCATION_ELEVATION, "exif:GPSAltitude", "exif:GPSAltitudeRef", serAltitude, serAltitudeRef, deAltitude));
    addMapping(s, createCompound(c.GST_TAG_GEO_LOCATION_MOVEMENT_SPEED, "exif:GPSSpeed", "exif:GPSSpeedRef", serSpeed, serSpeedRef, deSpeed));
    addMapping(s, createCompound(c.GST_TAG_GEO_LOCATION_MOVEMENT_DIRECTION, "exif:GPSTrack", "exif:GPSTrackRef", serDirection, serDirectionRef, deTrack));
    addMapping(s, createCompound(c.GST_TAG_GEO_LOCATION_CAPTURE_DIRECTION, "exif:GPSImgDirection", "exif:GPSImgDirectionRef", serDirection, serDirectionRef, deImgDirection));
    addSchema("exif", s);
    s = newSchema();
    simple(s, c.GST_TAG_GEO_LOCATION_COUNTRY, "photoshop:Country", .simple, null, null);
    simple(s, c.GST_TAG_GEO_LOCATION_CITY, "photoshop:City", .simple, null, null);
    addSchema("photoshop", s);
    s = newSchema();
    simple(s, c.GST_TAG_GEO_LOCATION_SUBLOCATION, "Iptc4xmpCore:Location", .simple, null, null);
    addSchema("Iptc4xmpCore", s);
    s = newSchema();
    const shown = create(null, "Iptc4xmpExt:LocationShown", .structure, null, null);
    shown.supertype = .bag;
    shown.parse_type = "Resource";
    shown.children = c.g_slist_prepend(shown.children, create(c.GST_TAG_GEO_LOCATION_SUBLOCATION, "LocationDetails:Sublocation", .simple, null, null));
    shown.children = c.g_slist_prepend(shown.children, create(c.GST_TAG_GEO_LOCATION_CITY, "LocationDetails:City", .simple, null, null));
    shown.children = c.g_slist_prepend(shown.children, create(c.GST_TAG_GEO_LOCATION_COUNTRY, "LocationDetails:Country", .simple, null, null));
    addMapping(s, shown);
    addSchema("Iptc4xmpExt", s);
    return null;
}

fn initialize() void {
    _ = c.g_once_impl(&init_once, initMap, null);
}

fn tagAt(p: c.gpointer) *Tag {
    return @ptrCast(@alignCast(p));
}

fn reverseInSchema(schema: ?*c.GHashTable, name: [*c]const u8, out: *?*Tag) bool {
    var it: c.GHashTableIter = undefined;
    var key: c.gpointer = null;
    var value: c.gpointer = null;
    c.g_hash_table_iter_init(&it, schema);
    while (c.g_hash_table_iter_next(&it, &key, &value) != 0) {
        const t = tagAt(value);
        if (t.name != null) {
            if (c.strcmp(t.name, name) == 0) {
                out.* = t;
                return true;
            }
        } else {
            var l = t.children;
            while (l) |n| : (l = n.next) {
                const ch = tagAt(n.data);
                if (c.strcmp(ch.name, name) == 0) {
                    out.* = ch;
                    return true;
                }
            }
        }
    }
    return false;
}

fn reverse(name: [*c]const u8, out: *?*Tag) void {
    var it: c.GHashTableIter = undefined;
    var key: c.gpointer = null;
    var value: c.gpointer = null;
    c.g_hash_table_iter_init(&it, schemas);
    while (c.g_hash_table_iter_next(&it, &key, &value) != 0) {
        if (reverseInSchema(@ptrCast(value), name, out)) return;
    }
}

fn fractionString(num: f64) [*c]u8 {
    var n: c.gint = 0;
    var d: c.gint = 0;
    c.gst_util_double_to_fraction(num, &n, &d);
    return c.g_strdup_printf("%d/%d", n, d);
}

fn serCoordinate(value: [*c]const c.GValue, pos: u8, neg: u8) [*c]u8 {
    if (!check.that(value[0].g_type == c.G_TYPE_DOUBLE, "serialize_exif_gps_coordinate", "G_VALUE_TYPE (value) == G_TYPE_DOUBLE")) return null;
    var num = c.g_value_get_double(value);
    var ch = pos;
    if (num < 0) {
        ch = neg;
        num *= -1;
    }
    const integer: c.gint = @intFromFloat(num);
    var frac: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
    _ = c.g_ascii_dtostr(&frac, frac.len, (num - @as(f64, @floatFromInt(integer))) * 60);
    return c.g_strdup_printf("%d,%s%c", integer, &frac, @as(c_int, ch));
}

fn serLatitude(v: [*c]const c.GValue) [*c]u8 {
    return serCoordinate(v, 'N', 'S');
}

fn serLongitude(v: [*c]const c.GValue) [*c]u8 {
    return serCoordinate(v, 'E', 'W');
}

fn deCoordinate(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, s: [*c]const u8, pos: u8, neg: u8) void {
    var d: c.gint = 0;
    var m: c.gint = 0;
    var sec: c.gint = 0;
    var m2: f64 = 0;
    var ch: u8 = 0;
    if (c.sscanf(s, "%d", &d) != 1) return;
    var cur = c.strchr(s, ',');
    if (cur != null) {
        cur += 1;
        if (c.strchr(cur, ',') != null) {
            if (c.sscanf(cur, "%d,%d%c", &m, &sec, &ch) == 0) return;
        } else {
            const copy = c.g_strdup(cur);
            var len: c.gint = @intCast(c.strlen(copy));
            const i = len - 1;
            var ok = true;
            while (len >= 0) : (len -= 1) {
                const b = copy[@bitCast(@as(isize, i))];
                if (c.g_ascii_isspace(b)) continue;
                if (c.g_ascii_isalpha(b)) {
                    ch = b;
                    copy[@bitCast(@as(isize, i))] = 0;
                    break;
                }
                ok = false;
                break;
            }
            if (!ok) {
                c.g_free(copy);
                return;
            }
            m2 = c.g_ascii_strtod(copy, null);
            c.g_free(copy);
        }
    }
    var value = @as(f64, @floatFromInt(d)) + @as(f64, @floatFromInt(m)) / 60.0 + @as(f64, @floatFromInt(sec)) / 3600.0 + m2 / 60.0;
    if (ch == neg) {
        value *= -1;
    } else if (ch != pos) return;
    c.gst_tag_list_add(list, mergeMode(t), gst_tag, value, NONE);
}

fn deLatitude(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, _: [*c]const u8, s: [*c]const u8, _: *?*c.GSList) void {
    deCoordinate(t, list, gst_tag, s, 'N', 'S');
}

fn deLongitude(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, _: [*c]const u8, s: [*c]const u8, _: *?*c.GSList) void {
    deCoordinate(t, list, gst_tag, s, 'E', 'W');
}

fn serAltitude(v: [*c]const c.GValue) [*c]u8 {
    const num = c.g_value_get_double(v);
    return fractionString(if (num < 0) -num else num);
}

fn serAltitudeRef(v: [*c]const c.GValue) [*c]u8 {
    return c.g_strdup(if (c.g_value_get_double(v) >= 0) "0" else "1");
}

fn pendingAt(n: *c.GSList) *Pending {
    return @ptrCast(@alignCast(n.data));
}

const Pair = struct { main: [*c]const u8, other: [*c]const u8, entry: ?*c.GSList, ptag: ?*Pending };

fn findPair(xmp_tag: [*c]const u8, s: [*c]const u8, a: [*c]const u8, b: [*c]const u8, pending: *?*c.GSList) ?Pair {
    var r = Pair{ .main = null, .other = null, .entry = null, .ptag = null };
    var want: [*c]const u8 = null;
    if (c.strcmp(xmp_tag, a) == 0) {
        r.main = s;
        want = b;
    } else if (c.strcmp(xmp_tag, b) == 0) {
        r.other = s;
        want = a;
    } else return null;
    var e = pending.*;
    while (e) |n| : (e = n.next) {
        const p = pendingAt(n);
        r.ptag = p;
        if (c.strcmp(p.tag.name, want) == 0) {
            if (r.main == null) r.main = p.str else r.other = p.str;
            r.entry = n;
            break;
        }
    }
    return r;
}

fn consume(pending: *?*c.GSList, r: Pair) void {
    const p = r.ptag.?;
    c.g_free(p.str);
    c.g_free(p);
    pending.* = c.g_slist_delete_link(pending.*, r.entry);
}

fn deAltitude(t: *Tag, list: [*c]c.GstTagList, _: [*c]const u8, xmp_tag: [*c]const u8, s: [*c]const u8, pending: *?*c.GSList) void {
    const r = findPair(xmp_tag, s, "exif:GPSAltitude", "exif:GPSAltitudeRef", pending) orelse return;
    if (r.main == null or r.other == null) return;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.sscanf(r.main, "%d/%d", &n, &d) != 2) return;
    var value: f64 = 0;
    c.gst_util_fraction_to_double(n, d, &value);
    if (r.other[0] == '1') {
        value *= -1;
    } else if (r.other[0] != '0') return;
    c.gst_tag_list_add(list, mergeMode(t), c.GST_TAG_GEO_LOCATION_ELEVATION, value, NONE);
    consume(pending, r);
}

fn serSpeed(v: [*c]const c.GValue) [*c]u8 {
    return fractionString(c.g_value_get_double(v) * 3.6);
}

fn serSpeedRef(_: [*c]const c.GValue) [*c]u8 {
    return c.g_strdup("K");
}

fn deSpeed(t: *Tag, list: [*c]c.GstTagList, _: [*c]const u8, xmp_tag: [*c]const u8, s: [*c]const u8, pending: *?*c.GSList) void {
    const r = findPair(xmp_tag, s, "exif:GPSSpeed", "exif:GPSSpeedRef", pending) orelse return;
    if (r.main == null or r.other == null) return;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.sscanf(r.main, "%d/%d", &n, &d) != 2) return;
    var value: f64 = 0;
    c.gst_util_fraction_to_double(n, d, &value);
    switch (r.other[0]) {
        'K' => value *= 1.0 / 3.6,
        'M' => value *= 0.44704,
        'N' => value *= 0.514444,
        else => return,
    }
    c.gst_tag_list_add(list, mergeMode(t), c.GST_TAG_GEO_LOCATION_MOVEMENT_SPEED, value, NONE);
    consume(pending, r);
}

fn serDirection(v: [*c]const c.GValue) [*c]u8 {
    return fractionString(c.g_value_get_double(v));
}

fn serDirectionRef(_: [*c]const c.GValue) [*c]u8 {
    return c.g_strdup("T");
}

fn deDirection(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, xmp_tag: [*c]const u8, s: [*c]const u8, pending: *?*c.GSList, a: [*c]const u8, b: [*c]const u8) void {
    const r = findPair(xmp_tag, s, a, b, pending) orelse return;
    if (r.main == null or r.other == null) return;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.sscanf(r.main, "%d/%d", &n, &d) != 2) return;
    var value: f64 = 0;
    c.gst_util_fraction_to_double(n, d, &value);
    if (r.other[0] != 'T') return;
    c.gst_tag_list_add(list, mergeMode(t), gst_tag, value, NONE);
    consume(pending, r);
}

fn deTrack(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, xmp_tag: [*c]const u8, s: [*c]const u8, pending: *?*c.GSList) void {
    deDirection(t, list, gst_tag, xmp_tag, s, pending, "exif:GPSTrack", "exif:GPSTrackRef");
}

fn deImgDirection(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, xmp_tag: [*c]const u8, s: [*c]const u8, pending: *?*c.GSList) void {
    deDirection(t, list, gst_tag, xmp_tag, s, pending, "exif:GPSImgDirection", "exif:GPSImgDirectionRef");
}

fn deRating(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, _: [*c]const u8, s: [*c]const u8, _: *?*c.GSList) void {
    var value: c.guint = 0;
    if (c.sscanf(s, "%u", &value) != 1) return;
    if (value > 100) return;
    c.gst_tag_list_add(list, mergeMode(t), gst_tag, value, NONE);
}

fn serOrientation(v: [*c]const c.GValue) [*c]u8 {
    const s = c.g_value_get_string(v);
    if (s == null) return null;
    const num = exifval.orientationToExif(s);
    if (num == -1) return null;
    return c.g_strdup_printf("%d", num);
}

fn deOrientation(t: *Tag, list: [*c]c.GstTagList, gst_tag: [*c]const u8, _: [*c]const u8, s: [*c]const u8, _: *?*c.GSList) void {
    var value: c.guint = 0;
    if (c.sscanf(s, "%u", &value) != 1) return;
    if (value < 1 or value > 8) return;
    const o = exifval.orientationFromExif(@intCast(value)) orelse return;
    c.gst_tag_list_add(list, mergeMode(t), gst_tag, o, NONE);
}

const NsMatch = struct { prefix: [*c]const u8, uri: [*c]const u8, extra: [*c]const u8 };

const NS = [_]NsMatch{
    .{ .prefix = "dc", .uri = "http://purl.org/dc/elements/1.1/", .extra = null },
    .{ .prefix = "exif", .uri = "http://ns.adobe.com/exif/1.0/", .extra = null },
    .{ .prefix = "tiff", .uri = "http://ns.adobe.com/tiff/1.0/", .extra = null },
    .{ .prefix = "xap", .uri = "http://ns.adobe.com/xap/1.0/", .extra = null },
    .{ .prefix = "photoshop", .uri = "http://ns.adobe.com/photoshop/1.0/", .extra = null },
    .{ .prefix = "Iptc4xmpCore", .uri = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/", .extra = null },
    .{ .prefix = "Iptc4xmpExt", .uri = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/", .extra = "xmlns:LocationDetails=\"http://iptc.org/std/Iptc4xmpExt/2008-02-29/LocationDetails/\"" },
};

fn readOne(list: [*c]c.GstTagList, t: *Tag, v: [*c]const u8, pending: *?*c.GSList) void {
    const tag = t.gst_tag;
    if (!check.that(tag != null, "read_one_tag", "tag != NULL")) return;
    if (t.deserialize) |f| {
        f(t, list, tag, t.name, v, pending);
        return;
    }
    const mode = mergeMode(t);
    const tt = c.gst_tag_get_type(tag);
    if (tt == c.G_TYPE_STRING) {
        c.gst_tag_list_add(list, mode, tag, v, NONE);
    } else if (tt == c.G_TYPE_DOUBLE) {
        var n: c.gint = 0;
        var d: c.gint = 0;
        if (c.sscanf(v, "%d/%d", &n, &d) == 2) {
            var value: f64 = 0;
            c.gst_util_fraction_to_double(n, d, &value);
            c.gst_tag_list_add(list, mode, tag, value, NONE);
        }
    } else if (tt == c.gst_date_time_get_type()) {
        if (v == null or v[0] == 0) return;
        const dt = c.gst_date_time_new_from_iso8601_string(v);
        if (dt != null) {
            c.gst_tag_list_add(list, mode, tag, dt, NONE);
            c.gst_date_time_unref(dt);
        }
    }
}

fn pushPending(pending: *?*c.GSList, t: *Tag, v: [*c]const u8) void {
    const p: *Pending = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Pending))));
    p.* = .{ .tag = t, .str = c.g_strdup(v) };
    pending.* = c.g_slist_prepend(pending.*, p);
}

fn isWs(ch: u8) bool {
    return ch == '\n' or ch == '\t' or ch == ' ';
}

pub export fn gst_tag_list_from_xmp_buffer(buffer: [*c]c.GstBuffer) [*c]c.GstTagList {
    initialize();
    const fname = "gst_tag_list_from_xmp_buffer";
    const is_buf = buffer != null and buffer[0].mini_object.type == c._gst_buffer_type;
    if (!check.that(is_buf, fname, "GST_IS_BUFFER (buffer)")) return null;
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(buffer, &info, c.GST_MAP_READ);
    const xps: [*c]u8 = info.data;
    const len = info.size;
    if (!check.that(len > 0, fname, "len > 0")) return null;
    defer c.gst_buffer_unmap(buffer, &info);
    const xpe = xps + len + 1;
    const head = "<?xpacket begin";
    var xp1 = c.g_strstr_len(xps, @intCast(len), head);
    if (xp1 == null) return null;
    xp1 += head.len;
    while (xp1[0] != '>' and xp1[0] != '<' and @intFromPtr(xp1) < @intFromPtr(xpe)) xp1 += 1;
    if (xp1[0] != '>') return null;
    const max_ft = 2 + "<?xpacket end=\".\"?>".len;
    if (len < max_ft) return null;
    const xp2 = c.g_strstr_len(xps + len - max_ft, max_ft, "<?xpacket ");
    if (xp2 == null) return null;
    xp1 += 1;
    while (xp1[0] != '<' and @intFromPtr(xp1) < @intFromPtr(xpe)) xp1 += 1;
    const part: [*c]u8 = @ptrCast(c.g_malloc(@intFromPtr(xp2) -% @intFromPtr(xp1)));
    defer c.g_free(part);
    var list = c.gst_tag_list_new_empty();
    var in_tag = true;
    var ns = xp1;
    var ne = xp1;
    var pp = part;
    var last: ?*Tag = null;
    var context: ?*Tag = null;
    var pending: ?*c.GSList = null;
    while (@intFromPtr(ne) < @intFromPtr(xp2)) {
        if (in_tag) {
            ne += 1;
            while (@intFromPtr(ne) < @intFromPtr(xp2) and ne[0] != '>' and ne[0] != '<') {
                if (isWs(ne[0])) {
                    while (@intFromPtr(ne) < @intFromPtr(xp2) and isWs(ne[0])) ne += 1;
                    pp[0] = ' ';
                    pp += 1;
                } else {
                    pp[0] = ne[0];
                    pp += 1;
                    ne += 1;
                }
            }
            pp[0] = 0;
            if (ne[0] != '>') {
                c.gst_tag_list_unref(list);
                list = null;
                freePending(pending);
                return list;
            }
            if (ns[0] != '/') {
                var as = c.strchr(part, ' ');
                if (as != null) {
                    as += 1;
                    var ae = as;
                    var d = as;
                    while (ae[0] != 0) {
                        if (ae[0] == '=') {
                            d = ae;
                        } else if (ae[0] == '"') {
                            ae += 1;
                            while (ae[0] != 0 and ae[0] != '"') ae += 1;
                            d[0] = 0;
                            ae[0] = 0;
                            const v = d + 2;
                            if (c.strncmp(as, "xmlns:", 6) != 0) {
                                var t: ?*Tag = null;
                                if (context) |ctx| {
                                    var l = ctx.children;
                                    while (l) |n| : (l = n.next) {
                                        const ch = tagAt(n.data);
                                        if (c.strcmp(ch.name, as) == 0) {
                                            t = ch;
                                            break;
                                        }
                                    }
                                } else reverse(as, &t);
                                if (t) |x| pushPending(&pending, x, v);
                            }
                            d[0] = '=';
                            ae[0] = '"';
                        } else if (ae[0] == 0 or ae[0] == ' ') as = ae + 1;
                        if (ae[0] != 0) ae += 1;
                    }
                } else if (c.strncmp(part, "rdf:", 4) != 0) {
                    if (context) |ctx| {
                        if (part[0] == '/' and c.strcmp(part + 1, ctx.name) == 0) {
                            context = null;
                        } else {
                            var l = ctx.children;
                            while (l) |n| : (l = n.next) {
                                const ch = tagAt(n.data);
                                if (c.strcmp(ch.name, part) == 0) {
                                    last = ch;
                                    break;
                                }
                            }
                        }
                    } else {
                        reverse(part, &last);
                        if (last != null and last.?.kind == .structure) {
                            context = last;
                            last = null;
                        }
                    }
                }
            }
            ne += 1;
            if (@intFromPtr(ne) < @intFromPtr(xp2)) {
                if (ne[0] != '<') in_tag = false;
                ns = ne;
                pp = part;
            }
        } else {
            while (@intFromPtr(ne) < @intFromPtr(xp2) and ne[0] != '<') {
                pp[0] = ne[0];
                pp += 1;
                ne += 1;
            }
            pp[0] = 0;
            if (ns[0] != '\n' and @intFromPtr(ns + 1) <= @intFromPtr(ne)) {
                if (last) |l| {
                    if (l.kind == .structure) {
                        context = l;
                    } else pushPending(&pending, l, part);
                }
            }
            in_tag = true;
            ns = ne;
            pp = part;
        }
    }
    pending = c.g_slist_reverse(pending);
    while (pending) |n| {
        const p = pendingAt(n);
        pending = c.g_slist_delete_link(pending, n);
        readOne(list, p.tag, p.str, &pending);
        c.g_free(p.str);
        c.g_free(p);
    }
    return list;
}

fn freePending(pending: ?*c.GSList) void {
    var l = pending;
    while (l) |n| : (l = n.next) {
        const p = pendingAt(n);
        c.g_free(p.str);
        c.g_free(p);
    }
    c.g_slist_free(pending);
}

fn openTag(s: *c.GString, tag: [*c]const u8) void {
    _ = c.g_string_append_c(s, '<');
    _ = c.g_string_append(s, tag);
    _ = c.g_string_append_c(s, '>');
}

fn closeTag(s: *c.GString, tag: [*c]const u8) void {
    _ = c.g_string_append(s, "</");
    _ = c.g_string_append(s, tag);
    _ = c.g_string_append(s, ">\n");
}

fn serializeValue(v: [*c]const c.GValue) [*c]u8 {
    const t = v[0].g_type;
    if (t == c.G_TYPE_STRING) return c.g_markup_escape_text(c.g_value_get_string(v), -1);
    if (t == c.G_TYPE_INT) return c.g_strdup_printf("%d", c.g_value_get_int(v));
    if (t == c.G_TYPE_UINT) return c.g_strdup_printf("%u", c.g_value_get_uint(v));
    if (t == c.G_TYPE_DOUBLE) return fractionString(c.g_value_get_double(v));
    if (t == c.g_date_get_type()) {
        const date: ?*const c.GDate = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        return c.g_strdup_printf("%04d-%02d-%02d", @as(c.gint, c.g_date_get_year(date)), @as(c.gint, @intCast(c.g_date_get_month(date))), @as(c.gint, c.g_date_get_day(date)));
    }
    if (t == c.gst_date_time_get_type()) {
        const dt: ?*c.GstDateTime = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
        if (c.gst_date_time_has_time(dt) == 0) return c.gst_date_time_to_iso8601_string(dt);
        const off: f32 = c.gst_date_time_get_time_zone_offset(dt);
        const y = c.gst_date_time_get_year(dt);
        const mo = c.gst_date_time_get_month(dt);
        const d = c.gst_date_time_get_day(dt);
        const h = c.gst_date_time_get_hour(dt);
        const mi = c.gst_date_time_get_minute(dt);
        const s = c.gst_date_time_get_second(dt);
        const us = c.gst_date_time_get_microsecond(dt);
        if (off == 0) return c.g_strdup_printf("%04d-%02d-%02dT%02d:%02d:%02d.%06dZ", y, mo, d, h, mi, s, us);
        const a = @abs(off);
        const oh: c.gint = @intFromFloat(a);
        const om: c.gint = @intFromFloat((a - @as(f32, @floatFromInt(oh))) * 60);
        return c.g_strdup_printf("%04d-%02d-%02dT%02d:%02d:%02d.%06d%c%02d:%02d", y, mo, d, h, mi, s, us, @as(c_int, if (off >= 0) '+' else '-'), oh, om);
    }
    return null;
}

fn writeOne(list: [*c]const c.GstTagList, t: *Tag, data: *c.GString) void {
    if (t.kind == .structure or t.kind == .compound) {
        var use = false;
        var l = t.children;
        while (l) |n| : (l = n.next) {
            if (c.gst_tag_list_get_value_index(list, tagAt(n.data).gst_tag, 0) != null) {
                use = true;
                break;
            }
        }
        if (!use) return;
        if (t.name != null) openTag(data, t.name);
        if (t.supertype != .none) {
            openTag(data, typeName(t.supertype));
            if (t.parse_type != null) {
                _ = c.g_string_append(data, "<rdf:li rdf:parseType=\"");
                _ = c.g_string_append(data, t.parse_type);
                _ = c.g_string_append_c(data, '"');
                _ = c.g_string_append_c(data, '>');
            } else openTag(data, "rdf:li");
        }
        l = t.children;
        while (l) |n| : (l = n.next) writeOne(list, tagAt(n.data), data);
        if (t.supertype != .none) {
            closeTag(data, "rdf:li");
            closeTag(data, typeName(t.supertype));
        }
        if (t.name != null) closeTag(data, t.name);
        return;
    }
    if (c.gst_tag_list_get_value_index(list, t.gst_tag, 0) == null) return;
    const ct = c.gst_tag_list_get_tag_size(list, t.gst_tag);
    openTag(data, t.name);
    if (ct == 1 or t.kind == .simple) {
        const v = c.gst_tag_list_get_value_index(list, t.gst_tag, 0);
        const s = if (t.serialize) |f| f(v) else serializeValue(v);
        if (s != null) {
            _ = c.g_string_append(data, s);
            c.g_free(s);
        }
    } else {
        const tn = typeName(t.kind);
        openTag(data, tn);
        var i: c.guint = 0;
        while (i < ct) : (i += 1) {
            const v = c.gst_tag_list_get_value_index(list, t.gst_tag, i);
            const s = if (t.serialize) |f| f(v) else serializeValue(v);
            if (s != null) {
                openTag(data, "rdf:li");
                _ = c.g_string_append(data, s);
                closeTag(data, "rdf:li");
                c.g_free(s);
            }
        }
        closeTag(data, tn);
    }
    closeTag(data, t.name);
}

fn useSchema(list: [*c][*c]const u8, name: [*c]const u8) bool {
    if (list == null) return true;
    var i: usize = 0;
    while (list[i] != null) : (i += 1) {
        if (c.strcmp(list[i], name) == 0) return true;
    }
    return false;
}

pub export fn gst_tag_list_to_xmp_buffer(list: [*c]const c.GstTagList, read_only: c.gboolean, schemas_in: [*c][*c]const u8) [*c]c.GstBuffer {
    const data: *c.GString = c.g_string_sized_new(4096);
    initialize();
    const is_list = list != null and list[0].mini_object.type == c.gst_tag_list_get_type();
    if (!check.that(is_list, "gst_tag_list_to_xmp_buffer", "GST_IS_TAG_LIST (list)")) return null;
    _ = c.g_string_append(data, "<?xpacket begin=\"\xEF\xBB\xBF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    _ = c.g_string_append(data, "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"GStreamer\">\n");
    _ = c.g_string_append(data, "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"");
    for (NS) |n| {
        if (!useSchema(schemas_in, n.prefix)) continue;
        c.g_string_append_printf(data, " xmlns:%s=\"%s\"", n.prefix, n.uri);
        if (n.extra != null) c.g_string_append_printf(data, " %s", n.extra);
    }
    _ = c.g_string_append(data, ">\n");
    _ = c.g_string_append(data, "<rdf:Description rdf:about=\"\">\n");
    const sl = if (schemas_in == null) gst_tag_xmp_list_schemas() else schemas_in;
    var i: usize = 0;
    while (sl[i] != null) : (i += 1) {
        const schema = getSchema(sl[i]) orelse continue;
        var it: c.GHashTableIter = undefined;
        var key: c.gpointer = null;
        var value: c.gpointer = null;
        c.g_hash_table_iter_init(&it, schema);
        while (c.g_hash_table_iter_next(&it, &key, &value) != 0) writeOne(list, tagAt(value), data);
    }
    _ = c.g_string_append(data, "</rdf:Description>\n");
    _ = c.g_string_append(data, "</rdf:RDF>\n");
    _ = c.g_string_append(data, "</x:xmpmeta>\n");
    if (read_only == 0) {
        for (0..32) |_| _ = c.g_string_append(data, "                                                                \n");
    }
    c.g_string_append_printf(data, "<?xpacket end=\"%c\"?>", @as(c_int, if (read_only != 0) 'r' else 'w'));
    const size = data.len;
    const bytes = c.g_string_free(data, 0);
    return c.gst_buffer_new_wrapped(bytes, size);
}
