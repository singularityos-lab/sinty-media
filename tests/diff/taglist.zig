const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn z(p: [*:0]const u8) [*c]const u8 {
    return p;
}

const end: ?*anyopaque = null;

const names = [_][*:0]const u8{ "title","title-sortname","artist","artist-sortname","album","album-sortname","album-artist","album-artist-sortname","date","datetime","genre","comment","extended-comment","track-number","track-count","album-disc-number","album-disc-count","location","homepage","description","version","isrc","organization","copyright","copyright-uri","encoded-by","contact","license","license-uri","performer","composer","conductor","duration","codec","video-codec","audio-codec","subtitle-codec","container-format","bitrate","nominal-bitrate","minimum-bitrate","maximum-bitrate","encoder","encoder-version","serial","replaygain-track-gain","r128-track-gain","replaygain-track-peak","replaygain-album-gain","r128-album-gain","replaygain-album-peak","replaygain-reference-level","language-code","language-name","image","preview-image","attachment","beats-per-minute","keywords","geo-location-name","geo-location-latitude","geo-location-longitude","geo-location-elevation","geo-location-country","geo-location-city","geo-location-sublocation","geo-location-horizontal-error","geo-location-movement-speed","geo-location-movement-direction","geo-location-capture-direction","show-name","show-sortname","show-episode-number","show-season-number","lyrics","composer-sortname","grouping","user-rating","device-manufacturer","device-model","application-name","application-data","image-orientation","publisher","interpreted-by","midi-base-note","private-data","container-specific-track-id", "unknown-tag" };

fn dump(label: []const u8, l: [*c]const c.GstTagList) void {
    if (l == null) {
        out("{s}: (null list)", .{label});
        return;
    }
    const t = c.gst_tag_list_to_string(l);
    out("{s}: {s} n {d} empty {d} scope {d}", .{ label, str(t), c.gst_tag_list_n_tags(l), c.gst_tag_list_is_empty(l), c.gst_tag_list_get_scope(l) });
    c.g_free(t);
}

fn each(l: [*c]const c.GstTagList, tag: [*c]const u8, _: c.gpointer) callconv(.c) void {
    out("  foreach {s} size {d}", .{ str(tag), c.gst_tag_list_get_tag_size(l, tag) });
}

fn withDouble(l: [*c]c.GstTagList, v: f64) [*c]c.GstTagList {
    var gv: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_DOUBLE);
    c.g_value_set_double(&gv, v);
    c.gst_tag_list_add_value(l, c.GST_TAG_MERGE_APPEND, "beats-per-minute", &gv);
    c.g_value_unset(&gv);
    return l;
}

fn base() [*c]c.GstTagList {
    const l = c.gst_tag_list_new(z("title"), z("One"), z("artist"), z("A"), z("track-number"), @as(c_uint, 3), z("duration"), @as(u64, 1234567), end);
    _ = withDouble(l, 120.5);
    c.gst_tag_list_add(l, c.GST_TAG_MERGE_APPEND, z("artist"), z("B"), z("comment"), z("first"), end);
    return l;
}

pub fn main() void {
    c.gst_init(null, null);
    for (names) |n| {
        if (c.gst_tag_exists(n) == 0) {
            out("tag {s} missing nick {s}", .{ str(n), str(c.gst_tag_get_nick(n)) });
            continue;
        }
        out("tag {s} type {s} nick {s} desc {s} flag {d} fixed {d}", .{ str(n), str(c.g_type_name(c.gst_tag_get_type(n))), str(c.gst_tag_get_nick(n)), str(c.gst_tag_get_description(n)), c.gst_tag_get_flag(n), c.gst_tag_is_fixed(n) });
    }
    c.gst_tag_register("my-tag", c.GST_TAG_FLAG_META, c.G_TYPE_STRING, "my tag", "custom tag", c.gst_tag_merge_strings_with_comma);
    c.gst_tag_register("my-tag", c.GST_TAG_FLAG_META, c.G_TYPE_INT, "my tag", "custom tag", null);
    c.gst_tag_register("my-int", c.GST_TAG_FLAG_ENCODED, c.G_TYPE_INT, "my int", "custom int", c.gst_tag_merge_use_first);
    out("custom {s} {s} {d}", .{ str(c.g_type_name(c.gst_tag_get_type("my-tag"))), str(c.gst_tag_get_description("my-int")), c.gst_tag_get_flag("my-int") });

    const l = base();
    dump("base", l);
    c.gst_tag_list_foreach(l, each, null);
    var i: c_uint = 0;
    while (i < @as(c_uint, @intCast(c.gst_tag_list_n_tags(l)))) : (i += 1) out("  nth {d} {s}", .{ i, str(c.gst_tag_list_nth_tag_name(l, i)) });

    var sv: [*c]u8 = null;
    out("get artist {d} {s}", .{ c.gst_tag_list_get_string(l, "artist", &sv), str(sv) });
    c.g_free(sv);
    sv = null;
    out("get artist 1 {d} {s}", .{ c.gst_tag_list_get_string_index(l, "artist", 1, &sv), str(sv) });
    c.g_free(sv);
    sv = null;
    out("get artist 2 {d}", .{c.gst_tag_list_get_string_index(l, "artist", 2, &sv)});
    var pv: [*c]const u8 = null;
    out("peek title {d} {s}", .{ c.gst_tag_list_peek_string_index(l, "title", 0, &pv), str(pv) });
    var u: c_uint = 0;
    out("uint {d} {d}", .{ c.gst_tag_list_get_uint(l, "track-number", &u), u });
    var u64v: u64 = 0;
    out("uint64 {d} {d}", .{ c.gst_tag_list_get_uint64(l, "duration", &u64v), u64v });
    var d: f64 = 0;
    out("double {d} {d}", .{ c.gst_tag_list_get_double(l, "beats-per-minute", &d), d });
    out("missing {d}", .{c.gst_tag_list_get_uint(l, "track-count", &u)});
    out("wrong-type {d}", .{c.gst_tag_list_get_int(l, "title", null)});

    const other = c.gst_tag_list_new(z("title"), z("Two"), z("album"), z("X"), z("track-number"), @as(c_uint, 9), z("comment"), z("second"), end);
    var mode: c_uint = c.GST_TAG_MERGE_UNDEFINED;
    while (mode <= c.GST_TAG_MERGE_COUNT) : (mode += 1) {
        const cp = c.gst_tag_list_copy(l);
        c.gst_tag_list_insert(cp, other, mode);
        var buf: [32]u8 = undefined;
        dump(std.fmt.bufPrint(&buf, "insert {d}", .{mode}) catch "insert", cp);
        const m = c.gst_tag_list_merge(l, other, mode);
        dump(std.fmt.bufPrint(&buf, "merge {d}", .{mode}) catch "merge", m);
        if (m != null) c.gst_tag_list_unref(m);
        c.gst_tag_list_unref(cp);
    }
    out("merge null null {d}", .{@intFromBool(c.gst_tag_list_merge(null, null, c.GST_TAG_MERGE_APPEND) == null)});
    const m1 = c.gst_tag_list_merge(l, null, c.GST_TAG_MERGE_REPLACE);
    dump("merge l null", m1);
    c.gst_tag_list_unref(m1);
    const m2 = c.gst_tag_list_merge(null, other, c.GST_TAG_MERGE_PREPEND);
    dump("merge null other", m2);
    c.gst_tag_list_unref(m2);

    const w = c.gst_tag_list_copy(l);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_PREPEND, z("artist"), z("Z"), z("my-tag"), z("m1"), z("my-tag"), z("m2"), z("my-int"), @as(c_int, 5), z("my-int"), @as(c_int, 6), end);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_KEEP, z("title"), z("Keep"), z("album"), z("Kept"), end);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_REPLACE, z("comment"), z("rep"), end);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_KEEP_ALL, z("genre"), z("Rock"), end);
    dump("modes", w);
    var iv: c_int = 0;
    out("my-int {d} {d} size {d}", .{ c.gst_tag_list_get_int(w, "my-int", &iv), iv, c.gst_tag_list_get_tag_size(w, "my-int") });
    sv = null;
    out("my-tag {d} {s}", .{ c.gst_tag_list_get_string(w, "my-tag", &sv), str(sv) });
    c.g_free(sv);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_APPEND, z("nope"), z("x"), end);
    var gv: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.G_TYPE_INT);
    c.g_value_set_int(&gv, 7);
    c.gst_tag_list_add_value(w, c.GST_TAG_MERGE_APPEND, "title", &gv);
    c.gst_tag_list_add_values(w, c.GST_TAG_MERGE_APPEND, z("my-int"), &gv, end);
    c.g_value_unset(&gv);
    c.gst_tag_list_add(w, c.GST_TAG_MERGE_APPEND, z("image"), @as(?*anyopaque, null), end);
    c.gst_tag_list_add(w, 0, z("title"), z("bad"), end);
    c.gst_tag_list_remove_tag(w, "comment");
    c.gst_tag_list_set_scope(w, c.GST_TAG_SCOPE_GLOBAL);
    dump("after", w);
    out("equal l l {d} l w {d}", .{ c.gst_tag_list_is_equal(l, l), c.gst_tag_list_is_equal(l, w) });

    const da = withDouble(c.gst_tag_list_new_empty(), 1.00000001);
    const db = withDouble(c.gst_tag_list_new_empty(), 1.00000002);
    const dc = withDouble(c.gst_tag_list_new_empty(), 1.1);
    out("double equal {d} {d}", .{ c.gst_tag_list_is_equal(da, db), c.gst_tag_list_is_equal(da, dc) });

    const date = c.g_date_new_dmy(14, c.G_DATE_MARCH, 2021);
    const dt = c.gst_date_time_new(1.0, 2021, 3, 14, 10, 20, 30.5);
    const dl = c.gst_tag_list_new(z("date"), date, z("datetime"), dt, end);
    dump("dates", dl);
    var gd: ?*c.GDate = null;
    out("get date {d} {d}", .{ c.gst_tag_list_get_date(dl, "date", &gd), c.g_date_get_year(gd) });
    c.g_date_free(gd);
    var gdt: ?*c.GstDateTime = null;
    out("get datetime {d} {d}", .{ c.gst_tag_list_get_date_time_index(dl, "datetime", 0, &gdt), c.gst_date_time_get_hour(gdt) });
    c.gst_date_time_unref(gdt);
    c.g_date_free(date);
    c.gst_date_time_unref(dt);

    const strs = [_][*:0]const u8{
        "taglist, title=(string)\"Hello World\", track-number=(uint)4, artist=(string){ A, B };",
        "taglist, title=(string)x, bogus",
        "taglist;",
        "foo, title=(string)x",
    };
    for (strs) |x| {
        const p = c.gst_tag_list_new_from_string(x);
        dump(std.mem.span(x), p);
        if (p != null) c.gst_tag_list_unref(p);
    }

    var tv: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&tv, c.gst_tag_list_get_type());
    c.g_value_set_boxed(&tv, l);
    const ser = c.gst_value_serialize(&tv);
    out("serialize {s}", .{str(ser)});
    var tv2: c.GValue = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&tv2, c.gst_tag_list_get_type());
    out("deserialize {d} compare {d}", .{ c.gst_value_deserialize(&tv2, ser), c.gst_value_compare(&tv, &tv2) });
    c.g_free(ser);
    const st = c.gst_structure_new("s", "tags", c.gst_tag_list_get_type(), l, end);
    const sts = c.gst_structure_to_string(st);
    out("structure {s}", .{str(sts)});
    const back = c.gst_structure_from_string(sts, null);
    out("structure back {d}", .{@intFromBool(back != null and c.gst_structure_is_equal(st, back) != 0)});
    c.g_free(sts);
    if (back != null) c.gst_structure_free(back);
    c.gst_structure_free(st);
    c.g_value_unset(&tv);
    c.g_value_unset(&tv2);

    var ref = c.gst_tag_list_ref(l);
    out("writable shared {d}", .{c.gst_tag_list_is_writable(l)});
    ref = c.gst_tag_list_make_writable(ref);
    out("made writable {d} same {d}", .{ c.gst_tag_list_is_writable(ref), @intFromBool(ref == l) });
    c.gst_tag_list_unref(ref);
    var slot: [*c]c.GstTagList = null;
    out("replace {d} take {d}", .{ c.gst_tag_list_replace(&slot, l), c.gst_tag_list_take(&slot, c.gst_tag_list_new_empty()) });
    c.gst_clear_tag_list(&slot);
    out("cleared {d}", .{@intFromBool(slot == null)});
    c.gst_tag_list_unref(da);
    c.gst_tag_list_unref(db);
    c.gst_tag_list_unref(dc);
    c.gst_tag_list_unref(dl);
    c.gst_tag_list_unref(w);
    c.gst_tag_list_unref(other);
    c.gst_tag_list_unref(l);
}
