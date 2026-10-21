const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const fields = @import("fields.zig");
const info = @import("info.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Query = c.GstQuery;
const Mini = c.GstMiniObject;
const Structure = c.GstStructure;
const NONE: u64 = std.math.maxInt(u64);

const Impl = extern struct {
    query: Query,
    s: [*c]Structure,
};

pub export var _gst_query_type: c.GType = 0;
var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

const Name = struct { t: c.GstQueryType, name: [:0]const u8 };

const names = [_]Name{
    .{ .t = c.GST_QUERY_UNKNOWN, .name = "unknown" },
    .{ .t = c.GST_QUERY_POSITION, .name = "position" },
    .{ .t = c.GST_QUERY_DURATION, .name = "duration" },
    .{ .t = c.GST_QUERY_LATENCY, .name = "latency" },
    .{ .t = c.GST_QUERY_JITTER, .name = "jitter" },
    .{ .t = c.GST_QUERY_RATE, .name = "rate" },
    .{ .t = c.GST_QUERY_SEEKING, .name = "seeking" },
    .{ .t = c.GST_QUERY_SEGMENT, .name = "segment" },
    .{ .t = c.GST_QUERY_CONVERT, .name = "convert" },
    .{ .t = c.GST_QUERY_FORMATS, .name = "formats" },
    .{ .t = c.GST_QUERY_BUFFERING, .name = "buffering" },
    .{ .t = c.GST_QUERY_CUSTOM, .name = "custom" },
    .{ .t = c.GST_QUERY_URI, .name = "uri" },
    .{ .t = c.GST_QUERY_ALLOCATION, .name = "allocation" },
    .{ .t = c.GST_QUERY_SCHEDULING, .name = "scheduling" },
    .{ .t = c.GST_QUERY_ACCEPT_CAPS, .name = "accept-caps" },
    .{ .t = c.GST_QUERY_CAPS, .name = "caps" },
    .{ .t = c.GST_QUERY_DRAIN, .name = "drain" },
    .{ .t = c.GST_QUERY_CONTEXT, .name = "context" },
    .{ .t = c.GST_QUERY_BITRATE, .name = "bitrate" },
    .{ .t = c.GST_QUERY_SELECTABLE, .name = "selectable" },
};

var quarks: [names.len]c.GQuark = .{0} ** names.len;

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn kind(p: anytype) c.GstQueryType {
    return impl(p).query.type;
}

fn structureOf(p: anytype) [*c]Structure {
    return impl(p).s;
}

fn value(q: anytype, name: [*c]const u8) [*c]const c.GValue {
    return c.gst_structure_get_value(structureOf(q), name);
}

fn isQuery(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_query_type;
}

pub export fn gst_query_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstQuery", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    debug_cat = info._gst_debug_category_new("query", 0, "query system");
    _gst_query_type = gst_query_get_type();
    for (names, 0..) |n, i| quarks[i] = c.g_quark_from_static_string(n.name.ptr);
}

pub export fn gst_query_type_get_name(t: c.GstQueryType) [*c]const u8 {
    for (names) |n| if (n.t == t) return n.name.ptr;
    return "unknown";
}

pub export fn gst_query_type_to_quark(t: c.GstQueryType) c.GQuark {
    for (names, 0..) |n, i| if (n.t == t) return quarks[i];
    return 0;
}

pub export fn gst_query_type_get_flags(t: c.GstQueryType) c.GstQueryTypeFlags {
    return t & ((1 << c.GST_QUERY_NUM_SHIFT) - 1);
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    if (!check.that(m != null, "_gst_query_free", "query != NULL")) return;
    const s = structureOf(m);
    if (s != null) {
        _ = c.gst_structure_set_parent_refcount(s, null);
        c.gst_structure_free(s);
    }
    c.g_free(m);
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    var s = structureOf(src);
    if (s != null) s = c.gst_structure_copy(s);
    return asMini(gst_query_new_custom(kind(src), s));
}

pub export fn gst_query_new_custom(t: c.GstQueryType, s: [*c]Structure) [*c]Query {
    const q: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    if (s != null and c.gst_structure_set_parent_refcount(s, &q.query.mini_object.refcount) == 0) {
        c.g_free(q);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "structure is already owned by another object");
        return null;
    }
    mini.gst_mini_object_init(asMini(q), 0, _gst_query_type, copyHook, null, freeHook);
    q.query.type = t;
    q.s = s;
    return @ptrCast(q);
}

fn is(comptime f: []const u8, q: [*c]Query, t: c.GstQueryType, comptime expr: []const u8) bool {
    return check.that(kind(q) == t, f, "GST_QUERY_TYPE (query) == " ++ expr);
}

fn isWritable(comptime f: []const u8, q: [*c]Query, t: c.GstQueryType, comptime expr: []const u8) bool {
    if (!is(f, q, t, expr)) return false;
    return check.that(gst_query_is_writable(q) != 0, f, "gst_query_is_writable (query)");
}

pub export fn gst_query_get_structure(q: [*c]Query) [*c]const Structure {
    if (!check.that(isQuery(q), "gst_query_get_structure", "GST_IS_QUERY (query)")) return null;
    return structureOf(q);
}

pub export fn gst_query_writable_structure(q: [*c]Query) [*c]Structure {
    const f = "gst_query_writable_structure";
    if (!check.that(isQuery(q), f, "GST_IS_QUERY (query)")) return null;
    if (!check.that(gst_query_is_writable(q) != 0, f, "gst_query_is_writable (query)")) return null;
    if (impl(q).s == null) {
        const s = c.gst_structure_new_static_str_empty(gst_query_type_get_name(kind(q)));
        _ = c.gst_structure_set_parent_refcount(s, &q[0].mini_object.refcount);
        impl(q).s = s;
    }
    return impl(q).s;
}

fn formatOf(q: [*c]Query, name: [*c]const u8) c.GstFormat {
    return @intCast(c.g_value_get_enum(value(q, name)));
}

fn amount(comptime name: [:0]const u8, t: c.GstQueryType, format: c.GstFormat, comptime field: [:0]const u8) [*c]Query {
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, field, c.G_TYPE_INT64, -1);
    return gst_query_new_custom(t, s);
}

pub export fn gst_query_new_position(format: c.GstFormat) [*c]Query {
    return amount("GstQueryPosition", c.GST_QUERY_POSITION, format, "current");
}

pub export fn gst_query_set_position(q: [*c]Query, format: c.GstFormat, cur: c.gint64) void {
    const f = "gst_query_set_position";
    if (!is(f, q, c.GST_QUERY_POSITION, "GST_QUERY_POSITION")) return;
    if (!check.that(format == formatOf(q, "format"), f, "format == g_value_get_enum (gst_structure_get_value (s, \"format\"))")) return;
    fields.set(structureOf(q), "format", c.gst_format_get_type(), format);
    fields.set(structureOf(q), "current", c.G_TYPE_INT64, cur);
}

pub export fn gst_query_parse_position(q: [*c]Query, format: [*c]c.GstFormat, cur: [*c]c.gint64) void {
    if (!is("gst_query_parse_position", q, c.GST_QUERY_POSITION, "GST_QUERY_POSITION")) return;
    if (format != null) format.* = formatOf(q, "format");
    if (cur != null) cur.* = c.g_value_get_int64(value(q, "current"));
}

pub export fn gst_query_new_duration(format: c.GstFormat) [*c]Query {
    return amount("GstQueryDuration", c.GST_QUERY_DURATION, format, "duration");
}

pub export fn gst_query_set_duration(q: [*c]Query, format: c.GstFormat, duration: c.gint64) void {
    const f = "gst_query_set_duration";
    if (!is(f, q, c.GST_QUERY_DURATION, "GST_QUERY_DURATION")) return;
    if (!check.that(format == formatOf(q, "format"), f, "format == g_value_get_enum (gst_structure_get_value (s, \"format\"))")) return;
    fields.set(structureOf(q), "format", c.gst_format_get_type(), format);
    fields.set(structureOf(q), "duration", c.G_TYPE_INT64, duration);
}

pub export fn gst_query_parse_duration(q: [*c]Query, format: [*c]c.GstFormat, duration: [*c]c.gint64) void {
    if (!is("gst_query_parse_duration", q, c.GST_QUERY_DURATION, "GST_QUERY_DURATION")) return;
    if (format != null) format.* = formatOf(q, "format");
    if (duration != null) duration.* = c.g_value_get_int64(value(q, "duration"));
}

pub export fn gst_query_new_latency() [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryLatency");
    fields.set(s, "live", c.G_TYPE_BOOLEAN, 0);
    fields.set(s, "min-latency", c.G_TYPE_UINT64, @as(u64, 0));
    fields.set(s, "max-latency", c.G_TYPE_UINT64, NONE);
    return gst_query_new_custom(c.GST_QUERY_LATENCY, s);
}

pub export fn gst_query_set_latency(q: [*c]Query, live: c.gboolean, min: c.GstClockTime, max: c.GstClockTime) void {
    const f = "gst_query_set_latency";
    if (!is(f, q, c.GST_QUERY_LATENCY, "GST_QUERY_LATENCY")) return;
    if (!check.that(min != NONE, f, "GST_CLOCK_TIME_IS_VALID (min_latency)")) return;
    const s = structureOf(q);
    fields.set(s, "live", c.G_TYPE_BOOLEAN, live);
    fields.set(s, "min-latency", c.G_TYPE_UINT64, min);
    fields.set(s, "max-latency", c.G_TYPE_UINT64, max);
}

pub export fn gst_query_parse_latency(q: [*c]Query, live: [*c]c.gboolean, min: [*c]c.GstClockTime, max: [*c]c.GstClockTime) void {
    if (!is("gst_query_parse_latency", q, c.GST_QUERY_LATENCY, "GST_QUERY_LATENCY")) return;
    if (live != null) live.* = c.g_value_get_boolean(value(q, "live"));
    if (min != null) min.* = c.g_value_get_uint64(value(q, "min-latency"));
    if (max != null) max.* = c.g_value_get_uint64(value(q, "max-latency"));
}

fn setConvert(s: [*c]Structure, src_format: c.GstFormat, src_value: c.gint64, dest_format: c.GstFormat, dest_value: c.gint64) void {
    fields.set(s, "src_format", c.gst_format_get_type(), src_format);
    fields.set(s, "src_value", c.G_TYPE_INT64, src_value);
    fields.set(s, "dest_format", c.gst_format_get_type(), dest_format);
    fields.set(s, "dest_value", c.G_TYPE_INT64, dest_value);
}

pub export fn gst_query_new_convert(src_format: c.GstFormat, v: c.gint64, dest_format: c.GstFormat) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryConvert");
    setConvert(s, src_format, v, dest_format, -1);
    return gst_query_new_custom(c.GST_QUERY_CONVERT, s);
}

pub export fn gst_query_set_convert(q: [*c]Query, src_format: c.GstFormat, src_value: c.gint64, dest_format: c.GstFormat, dest_value: c.gint64) void {
    if (!is("gst_query_set_convert", q, c.GST_QUERY_CONVERT, "GST_QUERY_CONVERT")) return;
    setConvert(structureOf(q), src_format, src_value, dest_format, dest_value);
}

pub export fn gst_query_parse_convert(q: [*c]Query, src_format: [*c]c.GstFormat, src_value: [*c]c.gint64, dest_format: [*c]c.GstFormat, dest_value: [*c]c.gint64) void {
    if (!is("gst_query_parse_convert", q, c.GST_QUERY_CONVERT, "GST_QUERY_CONVERT")) return;
    if (src_format != null) src_format.* = formatOf(q, "src_format");
    if (src_value != null) src_value.* = c.g_value_get_int64(value(q, "src_value"));
    if (dest_format != null) dest_format.* = formatOf(q, "dest_format");
    if (dest_value != null) dest_value.* = c.g_value_get_int64(value(q, "dest_value"));
}

fn setSegment(s: [*c]Structure, rate: c.gdouble, format: c.GstFormat, start: c.gint64, stop: c.gint64) void {
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "start_value", c.G_TYPE_INT64, start);
    fields.set(s, "stop_value", c.G_TYPE_INT64, stop);
}

pub export fn gst_query_new_segment(format: c.GstFormat) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQuerySegment");
    setSegment(s, 0.0, format, -1, -1);
    return gst_query_new_custom(c.GST_QUERY_SEGMENT, s);
}

pub export fn gst_query_set_segment(q: [*c]Query, rate: c.gdouble, format: c.GstFormat, start: c.gint64, stop: c.gint64) void {
    if (!is("gst_query_set_segment", q, c.GST_QUERY_SEGMENT, "GST_QUERY_SEGMENT")) return;
    setSegment(structureOf(q), rate, format, start, stop);
}

pub export fn gst_query_parse_segment(q: [*c]Query, rate: [*c]c.gdouble, format: [*c]c.GstFormat, start: [*c]c.gint64, stop: [*c]c.gint64) void {
    if (!is("gst_query_parse_segment", q, c.GST_QUERY_SEGMENT, "GST_QUERY_SEGMENT")) return;
    if (rate != null) rate.* = c.g_value_get_double(value(q, "rate"));
    if (format != null) format.* = formatOf(q, "format");
    if (start != null) start.* = c.g_value_get_int64(value(q, "start_value"));
    if (stop != null) stop.* = c.g_value_get_int64(value(q, "stop_value"));
}

fn setSeeking(s: [*c]Structure, format: c.GstFormat, seekable: c.gboolean, start: c.gint64, end: c.gint64) void {
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "seekable", c.G_TYPE_BOOLEAN, seekable);
    fields.set(s, "segment-start", c.G_TYPE_INT64, start);
    fields.set(s, "segment-end", c.G_TYPE_INT64, end);
}

pub export fn gst_query_new_seeking(format: c.GstFormat) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQuerySeeking");
    setSeeking(s, format, 0, -1, -1);
    return gst_query_new_custom(c.GST_QUERY_SEEKING, s);
}

pub export fn gst_query_set_seeking(q: [*c]Query, format: c.GstFormat, seekable: c.gboolean, start: c.gint64, end: c.gint64) void {
    if (!isWritable("gst_query_set_seeking", q, c.GST_QUERY_SEEKING, "GST_QUERY_SEEKING")) return;
    setSeeking(structureOf(q), format, seekable, start, end);
}

pub export fn gst_query_parse_seeking(q: [*c]Query, format: [*c]c.GstFormat, seekable: [*c]c.gboolean, start: [*c]c.gint64, end: [*c]c.gint64) void {
    if (!is("gst_query_parse_seeking", q, c.GST_QUERY_SEEKING, "GST_QUERY_SEEKING")) return;
    if (format != null) format.* = formatOf(q, "format");
    if (seekable != null) seekable.* = c.g_value_get_boolean(value(q, "seekable"));
    if (start != null) start.* = c.g_value_get_int64(value(q, "segment-start"));
    if (end != null) end.* = c.g_value_get_int64(value(q, "segment-end"));
}

fn array(s: [*c]Structure, name: [*c]const u8, comptime T: type, clear: c.GDestroyNotify) *c.GArray {
    const v = c.gst_structure_get_value(s, name);
    if (v != null) return @ptrCast(@alignCast(c.g_value_get_boxed(v)));
    const a = c.g_array_new(0, 1, @sizeOf(T));
    if (clear != null) c.g_array_set_clear_func(a, clear);
    var nv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&nv, c.g_array_get_type());
    c.g_value_take_boxed(&nv, a);
    c.gst_structure_take_value(s, name, &nv);
    return a;
}

fn items(comptime T: type, a: *c.GArray) []T {
    if (a.len == 0) return &.{};
    const p: [*]T = @ptrCast(@alignCast(a.data));
    return p[0..a.len];
}

fn append(comptime T: type, a: *c.GArray, item: T) void {
    var copy = item;
    _ = c.g_array_append_vals(a, &copy, 1);
}

pub export fn gst_query_new_formats() [*c]Query {
    return gst_query_new_custom(c.GST_QUERY_FORMATS, c.gst_structure_new_static_str_empty("GstQueryFormats"));
}

fn addFormat(list: *c.GValue, format: c.GstFormat) void {
    var item = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.gst_format_get_type());
    c.g_value_set_enum(&item, @intCast(format));
    c.gst_value_list_append_value(list, &item);
    c.g_value_unset(&item);
}

fn storeFormats(q: [*c]Query, list: *c.GValue) void {
    c.gst_structure_set_value(structureOf(q), "formats", list);
    c.g_value_unset(list);
}

pub export fn gst_query_set_formats(q: [*c]Query, n: c.gint, ...) callconv(.c) void {
    if (!isWritable("gst_query_set_formats", q, c.GST_QUERY_FORMATS, "GST_QUERY_FORMATS")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var i: c.gint = 0;
    while (i < n) : (i += 1) addFormat(&list, @cVaArg(&ap, c.GstFormat));
    storeFormats(q, &list);
}

pub export fn gst_query_set_formatsv(q: [*c]Query, n: c.gint, formats: [*c]const c.GstFormat) void {
    if (!isWritable("gst_query_set_formatsv", q, c.GST_QUERY_FORMATS, "GST_QUERY_FORMATS")) return;
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var i: usize = 0;
    while (i < n) : (i += 1) addFormat(&list, formats[i]);
    storeFormats(q, &list);
}

pub export fn gst_query_parse_n_formats(q: [*c]Query, n: [*c]c.guint) void {
    if (!is("gst_query_parse_n_formats", q, c.GST_QUERY_FORMATS, "GST_QUERY_FORMATS")) return;
    if (n == null) return;
    const list = value(q, "formats");
    n.* = if (list == null) 0 else c.gst_value_list_get_size(list);
}

pub export fn gst_query_parse_nth_format(q: [*c]Query, nth: c.guint, format: [*c]c.GstFormat) void {
    if (!is("gst_query_parse_nth_format", q, c.GST_QUERY_FORMATS, "GST_QUERY_FORMATS")) return;
    if (format == null) return;
    const list = value(q, "formats");
    format.* = c.GST_FORMAT_UNDEFINED;
    if (list != null and nth < c.gst_value_list_get_size(list)) format.* = @intCast(c.g_value_get_enum(c.gst_value_list_get_value(list, nth)));
}

pub export fn gst_query_new_buffering(format: c.GstFormat) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryBuffering");
    fields.set(s, "busy", c.G_TYPE_BOOLEAN, 0);
    fields.set(s, "buffer-percent", c.G_TYPE_INT, 100);
    fields.set(s, "buffering-mode", c.gst_buffering_mode_get_type(), c.GST_BUFFERING_STREAM);
    fields.set(s, "avg-in-rate", c.G_TYPE_INT, -1);
    fields.set(s, "avg-out-rate", c.G_TYPE_INT, -1);
    fields.set(s, "buffering-left", c.G_TYPE_INT64, 0);
    fields.set(s, "estimated-total", c.G_TYPE_INT64, -1);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "start_value", c.G_TYPE_INT64, -1);
    fields.set(s, "stop_value", c.G_TYPE_INT64, -1);
    return gst_query_new_custom(c.GST_QUERY_BUFFERING, s);
}

pub export fn gst_query_set_buffering_percent(q: [*c]Query, busy: c.gboolean, percent: c.gint) void {
    const f = "gst_query_set_buffering_percent";
    if (!isWritable(f, q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    if (!check.that(percent >= 0 and percent <= 100, f, "percent >= 0 && percent <= 100")) return;
    fields.set(structureOf(q), "busy", c.G_TYPE_BOOLEAN, busy);
    fields.set(structureOf(q), "buffer-percent", c.G_TYPE_INT, percent);
}

pub export fn gst_query_parse_buffering_percent(q: [*c]Query, busy: [*c]c.gboolean, percent: [*c]c.gint) void {
    if (!is("gst_query_parse_buffering_percent", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    if (busy != null) busy.* = c.g_value_get_boolean(value(q, "busy"));
    if (percent != null) percent.* = c.g_value_get_int(value(q, "buffer-percent"));
}

pub export fn gst_query_set_buffering_stats(q: [*c]Query, mode: c.GstBufferingMode, avg_in: c.gint, avg_out: c.gint, left: c.gint64) void {
    if (!isWritable("gst_query_set_buffering_stats", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    const s = structureOf(q);
    fields.set(s, "buffering-mode", c.gst_buffering_mode_get_type(), mode);
    fields.set(s, "avg-in-rate", c.G_TYPE_INT, avg_in);
    fields.set(s, "avg-out-rate", c.G_TYPE_INT, avg_out);
    fields.set(s, "buffering-left", c.G_TYPE_INT64, left);
}

pub export fn gst_query_parse_buffering_stats(q: [*c]Query, mode: [*c]c.GstBufferingMode, avg_in: [*c]c.gint, avg_out: [*c]c.gint, left: [*c]c.gint64) void {
    if (!is("gst_query_parse_buffering_stats", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    if (mode != null) mode.* = @intCast(c.g_value_get_enum(value(q, "buffering-mode")));
    if (avg_in != null) avg_in.* = c.g_value_get_int(value(q, "avg-in-rate"));
    if (avg_out != null) avg_out.* = c.g_value_get_int(value(q, "avg-out-rate"));
    if (left != null) left.* = c.g_value_get_int64(value(q, "buffering-left"));
}

pub export fn gst_query_set_buffering_range(q: [*c]Query, format: c.GstFormat, start: c.gint64, stop: c.gint64, total: c.gint64) void {
    if (!isWritable("gst_query_set_buffering_range", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    const s = structureOf(q);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "start_value", c.G_TYPE_INT64, start);
    fields.set(s, "stop_value", c.G_TYPE_INT64, stop);
    fields.set(s, "estimated-total", c.G_TYPE_INT64, total);
}

pub export fn gst_query_parse_buffering_range(q: [*c]Query, format: [*c]c.GstFormat, start: [*c]c.gint64, stop: [*c]c.gint64, total: [*c]c.gint64) void {
    if (!is("gst_query_parse_buffering_range", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return;
    if (format != null) format.* = formatOf(q, "format");
    if (start != null) start.* = c.g_value_get_int64(value(q, "start_value"));
    if (stop != null) stop.* = c.g_value_get_int64(value(q, "stop_value"));
    if (total != null) total.* = c.g_value_get_int64(value(q, "estimated-total"));
}

const Range = extern struct { start: c.gint64, stop: c.gint64 };

fn ranges(q: [*c]Query) *c.GArray {
    return array(structureOf(q), "buffering-ranges", Range, null);
}

pub export fn gst_query_add_buffering_range(q: [*c]Query, start: c.gint64, stop: c.gint64) c.gboolean {
    if (!isWritable("gst_query_add_buffering_range", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return 0;
    if (start >= stop) return 0;
    const a = ranges(q);
    const list = items(Range, a);
    if (list.len > 1 and start <= list[list.len - 1].start) return 0;
    append(Range, a, .{ .start = start, .stop = stop });
    return 1;
}

pub export fn gst_query_get_n_buffering_ranges(q: [*c]Query) c.guint {
    if (!is("gst_query_get_n_buffering_ranges", q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return 0;
    return ranges(q).len;
}

pub export fn gst_query_parse_nth_buffering_range(q: [*c]Query, idx: c.guint, start: [*c]c.gint64, stop: [*c]c.gint64) c.gboolean {
    const f = "gst_query_parse_nth_buffering_range";
    if (!is(f, q, c.GST_QUERY_BUFFERING, "GST_QUERY_BUFFERING")) return 0;
    const list = items(Range, ranges(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return 0;
    if (start != null) start.* = list[idx].start;
    if (stop != null) stop.* = list[idx].stop;
    return 1;
}

pub export fn gst_query_new_uri() [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryURI");
    fields.set(s, "uri", c.G_TYPE_STRING, @as([*c]const u8, null));
    return gst_query_new_custom(c.GST_QUERY_URI, s);
}

pub export fn gst_query_set_uri(q: [*c]Query, uri: [*c]const u8) void {
    if (!isWritable("gst_query_set_uri", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    fields.set(structureOf(q), "uri", c.G_TYPE_STRING, uri);
}

pub export fn gst_query_parse_uri(q: [*c]Query, uri: [*c][*c]u8) void {
    if (!is("gst_query_parse_uri", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    if (uri != null) uri.* = c.g_value_dup_string(value(q, "uri"));
}

pub export fn gst_query_set_uri_redirection(q: [*c]Query, uri: [*c]const u8) void {
    if (!isWritable("gst_query_set_uri_redirection", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    fields.set(structureOf(q), "uri-redirection", c.G_TYPE_STRING, uri);
}

pub export fn gst_query_parse_uri_redirection(q: [*c]Query, uri: [*c][*c]u8) void {
    if (!is("gst_query_parse_uri_redirection", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    if (uri == null) return;
    if (c.gst_structure_get(structureOf(q), "uri-redirection", c.G_TYPE_STRING, uri, @as(?*anyopaque, null)) == 0) uri.* = null;
}

pub export fn gst_query_set_uri_redirection_permanent(q: [*c]Query, permanent: c.gboolean) void {
    if (!isWritable("gst_query_set_uri_redirection_permanent", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    fields.set(structureOf(q), "uri-redirection-permanent", c.G_TYPE_BOOLEAN, permanent);
}

pub export fn gst_query_parse_uri_redirection_permanent(q: [*c]Query, permanent: [*c]c.gboolean) void {
    if (!is("gst_query_parse_uri_redirection_permanent", q, c.GST_QUERY_URI, "GST_QUERY_URI")) return;
    if (permanent == null) return;
    if (c.gst_structure_get(structureOf(q), "uri-redirection-permanent", c.G_TYPE_BOOLEAN, permanent, @as(?*anyopaque, null)) == 0) permanent.* = 0;
}

pub export fn gst_query_new_allocation(caps: [*c]c.GstCaps, need_pool: c.gboolean) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryAllocation");
    fields.set(s, "caps", c.gst_caps_get_type(), caps);
    fields.set(s, "need-pool", c.G_TYPE_BOOLEAN, need_pool);
    return gst_query_new_custom(c.GST_QUERY_ALLOCATION, s);
}

pub export fn gst_query_parse_allocation(q: [*c]Query, caps: [*c][*c]c.GstCaps, need_pool: [*c]c.gboolean) void {
    if (!is("gst_query_parse_allocation", q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    if (caps != null) caps.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(q, "caps"))));
    _ = c.gst_structure_get(structureOf(q), "need-pool", c.G_TYPE_BOOLEAN, need_pool, @as(?*anyopaque, null));
}

const Pool = extern struct {
    pool: [*c]c.GstBufferPool,
    size: c.guint,
    min: c.guint,
    max: c.guint,
};

fn clearPool(p: c.gpointer) callconv(.c) void {
    const ap: *Pool = @ptrCast(@alignCast(p));
    if (ap.pool != null) c.gst_object_unref(ap.pool);
}

fn pools(q: [*c]Query) *c.GArray {
    return array(structureOf(q), "pool", Pool, clearPool);
}

fn pooled(pool: [*c]c.GstBufferPool, size: c.guint, min: c.guint, max: c.guint) Pool {
    if (pool != null) _ = c.gst_object_ref(pool);
    return .{ .pool = pool, .size = size, .min = min, .max = max };
}

pub export fn gst_query_add_allocation_pool(q: [*c]Query, pool: [*c]c.GstBufferPool, size: c.guint, min: c.guint, max: c.guint) void {
    if (!isWritable("gst_query_add_allocation_pool", q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    append(Pool, pools(q), pooled(pool, size, min, max));
}

pub export fn gst_query_get_n_allocation_pools(q: [*c]Query) c.guint {
    if (!is("gst_query_get_n_allocation_pools", q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return 0;
    return pools(q).len;
}

pub export fn gst_query_parse_nth_allocation_pool(q: [*c]Query, idx: c.guint, pool: [*c][*c]c.GstBufferPool, size: [*c]c.guint, min: [*c]c.guint, max: [*c]c.guint) void {
    const f = "gst_query_parse_nth_allocation_pool";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const list = items(Pool, pools(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return;
    const ap = list[idx];
    if (pool != null) {
        pool.* = ap.pool;
        if (ap.pool != null) _ = c.gst_object_ref(ap.pool);
    }
    if (size != null) size.* = ap.size;
    if (min != null) min.* = ap.min;
    if (max != null) max.* = ap.max;
}

pub export fn gst_query_set_nth_allocation_pool(q: [*c]Query, idx: c.guint, pool: [*c]c.GstBufferPool, size: c.guint, min: c.guint, max: c.guint) void {
    const f = "gst_query_set_nth_allocation_pool";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const list = items(Pool, pools(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return;
    clearPool(&list[idx]);
    list[idx] = pooled(pool, size, min, max);
}

pub export fn gst_query_remove_nth_allocation_pool(q: [*c]Query, idx: c.guint) void {
    const f = "gst_query_remove_nth_allocation_pool";
    if (!isWritable(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const a = pools(q);
    if (!check.that(idx < a.len, f, "index < array->len")) return;
    _ = c.g_array_remove_index(a, idx);
}

const Meta = extern struct {
    api: c.GType,
    params: [*c]Structure,
};

fn clearMeta(p: c.gpointer) callconv(.c) void {
    const am: *Meta = @ptrCast(@alignCast(p));
    if (am.params != null) c.gst_structure_free(am.params);
}

fn metas(q: [*c]Query) *c.GArray {
    return array(structureOf(q), "meta", Meta, clearMeta);
}

pub export fn gst_query_add_allocation_meta(q: [*c]Query, api: c.GType, params: [*c]const Structure) void {
    const f = "gst_query_add_allocation_meta";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    if (!check.that(api != 0, f, "api != 0")) return;
    if (!check.that(gst_query_is_writable(q) != 0, f, "gst_query_is_writable (query)")) return;
    append(Meta, metas(q), .{ .api = api, .params = if (params != null) c.gst_structure_copy(params) else null });
}

pub export fn gst_query_get_n_allocation_metas(q: [*c]Query) c.guint {
    if (!is("gst_query_get_n_allocation_metas", q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return 0;
    return metas(q).len;
}

pub export fn gst_query_parse_nth_allocation_meta(q: [*c]Query, idx: c.guint, params: [*c][*c]const Structure) c.GType {
    const f = "gst_query_parse_nth_allocation_meta";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return 0;
    const list = items(Meta, metas(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return 0;
    if (params != null) params.* = list[idx].params;
    return list[idx].api;
}

pub export fn gst_query_remove_nth_allocation_meta(q: [*c]Query, idx: c.guint) void {
    const f = "gst_query_remove_nth_allocation_meta";
    if (!isWritable(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const a = metas(q);
    if (!check.that(idx < a.len, f, "index < array->len")) return;
    _ = c.g_array_remove_index(a, idx);
}

pub export fn gst_query_find_allocation_meta(q: [*c]Query, api: c.GType, idx: [*c]c.guint) c.gboolean {
    const f = "gst_query_find_allocation_meta";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return 0;
    if (!check.that(api != 0, f, "api != 0")) return 0;
    for (items(Meta, metas(q)), 0..) |am, i| {
        if (am.api != api) continue;
        if (idx != null) idx.* = @intCast(i);
        return 1;
    }
    return 0;
}

const Param = extern struct {
    allocator: [*c]c.GstAllocator,
    params: c.GstAllocationParams,
};

fn clearParam(p: c.gpointer) callconv(.c) void {
    const ap: *Param = @ptrCast(@alignCast(p));
    if (ap.allocator != null) c.gst_object_unref(ap.allocator);
}

fn allocParams(q: [*c]Query) *c.GArray {
    return array(structureOf(q), "allocator", Param, clearParam);
}

fn param(allocator: [*c]c.GstAllocator, p: [*c]const c.GstAllocationParams) Param {
    if (allocator != null) _ = c.gst_object_ref(allocator);
    return .{ .allocator = allocator, .params = if (p != null) p[0] else std.mem.zeroes(c.GstAllocationParams) };
}

pub export fn gst_query_add_allocation_param(q: [*c]Query, allocator: [*c]c.GstAllocator, p: [*c]const c.GstAllocationParams) void {
    const f = "gst_query_add_allocation_param";
    if (!isWritable(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    if (!check.that(allocator != null or p != null, f, "allocator != NULL || params != NULL")) return;
    append(Param, allocParams(q), param(allocator, p));
}

pub export fn gst_query_get_n_allocation_params(q: [*c]Query) c.guint {
    if (!is("gst_query_get_n_allocation_params", q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return 0;
    return allocParams(q).len;
}

pub export fn gst_query_parse_nth_allocation_param(q: [*c]Query, idx: c.guint, allocator: [*c][*c]c.GstAllocator, p: [*c]c.GstAllocationParams) void {
    const f = "gst_query_parse_nth_allocation_param";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const list = items(Param, allocParams(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return;
    if (allocator != null) {
        allocator.* = list[idx].allocator;
        if (list[idx].allocator != null) _ = c.gst_object_ref(list[idx].allocator);
    }
    if (p != null) p[0] = list[idx].params;
}

pub export fn gst_query_set_nth_allocation_param(q: [*c]Query, idx: c.guint, allocator: [*c]c.GstAllocator, p: [*c]const c.GstAllocationParams) void {
    const f = "gst_query_set_nth_allocation_param";
    if (!is(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const list = items(Param, allocParams(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return;
    clearParam(&list[idx]);
    list[idx] = param(allocator, p);
}

pub export fn gst_query_remove_nth_allocation_param(q: [*c]Query, idx: c.guint) void {
    const f = "gst_query_remove_nth_allocation_param";
    if (!isWritable(f, q, c.GST_QUERY_ALLOCATION, "GST_QUERY_ALLOCATION")) return;
    const a = allocParams(q);
    if (!check.that(idx < a.len, f, "index < array->len")) return;
    _ = c.g_array_remove_index(a, idx);
}

fn setScheduling(s: [*c]Structure, flags: c.GstSchedulingFlags, min: c.gint, max: c.gint, alignment: c.gint) void {
    fields.set(s, "flags", c.gst_scheduling_flags_get_type(), flags);
    fields.set(s, "minsize", c.G_TYPE_INT, min);
    fields.set(s, "maxsize", c.G_TYPE_INT, max);
    fields.set(s, "align", c.G_TYPE_INT, alignment);
}

pub export fn gst_query_new_scheduling() [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryScheduling");
    setScheduling(s, 0, 1, -1, 0);
    return gst_query_new_custom(c.GST_QUERY_SCHEDULING, s);
}

pub export fn gst_query_set_scheduling(q: [*c]Query, flags: c.GstSchedulingFlags, min: c.gint, max: c.gint, alignment: c.gint) void {
    if (!isWritable("gst_query_set_scheduling", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return;
    setScheduling(structureOf(q), flags, min, max, alignment);
}

pub export fn gst_query_parse_scheduling(q: [*c]Query, flags: [*c]c.GstSchedulingFlags, min: [*c]c.gint, max: [*c]c.gint, alignment: [*c]c.gint) void {
    if (!is("gst_query_parse_scheduling", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return;
    _ = c.gst_structure_get(structureOf(q), "flags", c.gst_scheduling_flags_get_type(), flags, "minsize", c.G_TYPE_INT, min, "maxsize", c.G_TYPE_INT, max, "align", c.G_TYPE_INT, alignment, @as(?*anyopaque, null));
}

fn modes(q: [*c]Query) *c.GArray {
    return array(structureOf(q), "modes", c.GstPadMode, null);
}

pub export fn gst_query_add_scheduling_mode(q: [*c]Query, mode: c.GstPadMode) void {
    if (!isWritable("gst_query_add_scheduling_mode", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return;
    append(c.GstPadMode, modes(q), mode);
}

pub export fn gst_query_get_n_scheduling_modes(q: [*c]Query) c.guint {
    if (!is("gst_query_get_n_scheduling_modes", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return 0;
    return modes(q).len;
}

pub export fn gst_query_parse_nth_scheduling_mode(q: [*c]Query, idx: c.guint) c.GstPadMode {
    const f = "gst_query_parse_nth_scheduling_mode";
    if (!is(f, q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return c.GST_PAD_MODE_NONE;
    const list = items(c.GstPadMode, modes(q));
    if (!check.that(idx < list.len, f, "index < array->len")) return c.GST_PAD_MODE_NONE;
    return list[idx];
}

pub export fn gst_query_has_scheduling_mode(q: [*c]Query, mode: c.GstPadMode) c.gboolean {
    if (!is("gst_query_has_scheduling_mode", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return 0;
    for (items(c.GstPadMode, modes(q))) |m| if (m == mode) return 1;
    return 0;
}

pub export fn gst_query_has_scheduling_mode_with_flags(q: [*c]Query, mode: c.GstPadMode, flags: c.GstSchedulingFlags) c.gboolean {
    if (!is("gst_query_has_scheduling_mode_with_flags", q, c.GST_QUERY_SCHEDULING, "GST_QUERY_SCHEDULING")) return 0;
    var have: c.GstSchedulingFlags = 0;
    gst_query_parse_scheduling(q, &have, null, null, null);
    return @intFromBool(flags & have == flags and gst_query_has_scheduling_mode(q, mode) != 0);
}

pub export fn gst_query_new_accept_caps(caps: [*c]c.GstCaps) [*c]Query {
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, "gst_query_new_accept_caps", "gst_caps_is_fixed (caps)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstQueryAcceptCaps");
    fields.set(s, "caps", c.gst_caps_get_type(), caps);
    fields.set(s, "result", c.G_TYPE_BOOLEAN, 0);
    return gst_query_new_custom(c.GST_QUERY_ACCEPT_CAPS, s);
}

pub export fn gst_query_parse_accept_caps(q: [*c]Query, caps: [*c][*c]c.GstCaps) void {
    const f = "gst_query_parse_accept_caps";
    if (!is(f, q, c.GST_QUERY_ACCEPT_CAPS, "GST_QUERY_ACCEPT_CAPS")) return;
    if (!check.that(caps != null, f, "caps != NULL")) return;
    caps.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(q, "caps"))));
}

pub export fn gst_query_set_accept_caps_result(q: [*c]Query, result: c.gboolean) void {
    if (!isWritable("gst_query_set_accept_caps_result", q, c.GST_QUERY_ACCEPT_CAPS, "GST_QUERY_ACCEPT_CAPS")) return;
    fields.set(structureOf(q), "result", c.G_TYPE_BOOLEAN, result);
}

pub export fn gst_query_parse_accept_caps_result(q: [*c]Query, result: [*c]c.gboolean) void {
    if (!is("gst_query_parse_accept_caps_result", q, c.GST_QUERY_ACCEPT_CAPS, "GST_QUERY_ACCEPT_CAPS")) return;
    _ = c.gst_structure_get(structureOf(q), "result", c.G_TYPE_BOOLEAN, result, @as(?*anyopaque, null));
}

pub export fn gst_query_new_caps(filter: [*c]c.GstCaps) [*c]Query {
    const s = c.gst_structure_new_static_str_empty("GstQueryCaps");
    fields.set(s, "filter", c.gst_caps_get_type(), filter);
    fields.set(s, "caps", c.gst_caps_get_type(), @as([*c]c.GstCaps, null));
    return gst_query_new_custom(c.GST_QUERY_CAPS, s);
}

pub export fn gst_query_parse_caps(q: [*c]Query, filter: [*c][*c]c.GstCaps) void {
    const f = "gst_query_parse_caps";
    if (!is(f, q, c.GST_QUERY_CAPS, "GST_QUERY_CAPS")) return;
    if (!check.that(filter != null, f, "filter != NULL")) return;
    filter.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(q, "filter"))));
}

pub export fn gst_query_set_caps_result(q: [*c]Query, caps: [*c]c.GstCaps) void {
    if (!isWritable("gst_query_set_caps_result", q, c.GST_QUERY_CAPS, "GST_QUERY_CAPS")) return;
    fields.set(structureOf(q), "caps", c.gst_caps_get_type(), caps);
}

pub export fn gst_query_parse_caps_result(q: [*c]Query, caps: [*c][*c]c.GstCaps) void {
    const f = "gst_query_parse_caps_result";
    if (!is(f, q, c.GST_QUERY_CAPS, "GST_QUERY_CAPS")) return;
    if (!check.that(caps != null, f, "caps != NULL")) return;
    caps.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(q, "caps"))));
}

pub export fn gst_query_new_drain() [*c]Query {
    return gst_query_new_custom(c.GST_QUERY_DRAIN, c.gst_structure_new_static_str_empty("GstQueryDrain"));
}

pub export fn gst_query_new_context(ctx_type: [*c]const u8) [*c]Query {
    if (!check.that(ctx_type != null, "gst_query_new_context", "context_type != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstQueryContext");
    fields.set(s, "context-type", c.G_TYPE_STRING, ctx_type);
    return gst_query_new_custom(c.GST_QUERY_CONTEXT, s);
}

pub export fn gst_query_set_context(q: [*c]Query, ctx: ?*c.GstContext) void {
    const f = "gst_query_set_context";
    if (!is(f, q, c.GST_QUERY_CONTEXT, "GST_QUERY_CONTEXT")) return;
    var want: [*c]const u8 = null;
    _ = gst_query_parse_context_type(q, &want);
    if (!check.that(c.strcmp(c.gst_context_get_context_type(ctx), want) == 0, f, "strcmp (gst_context_get_context_type (context), context_type) == 0")) return;
    fields.set(structureOf(q), "context", c.gst_context_get_type(), ctx);
}

pub export fn gst_query_parse_context(q: [*c]Query, ctx: [*c]?*c.GstContext) void {
    const f = "gst_query_parse_context";
    if (!is(f, q, c.GST_QUERY_CONTEXT, "GST_QUERY_CONTEXT")) return;
    if (!check.that(ctx != null, f, "context != NULL")) return;
    const v = value(q, "context");
    ctx.* = if (v != null) @ptrCast(c.g_value_get_boxed(v)) else null;
}

pub export fn gst_query_parse_context_type(q: [*c]Query, ctx_type: [*c][*c]const u8) c.gboolean {
    if (!is("gst_query_parse_context_type", q, c.GST_QUERY_CONTEXT, "GST_QUERY_CONTEXT")) return 0;
    if (ctx_type != null) ctx_type.* = c.g_value_get_string(value(q, "context-type"));
    return 1;
}

pub export fn gst_query_new_bitrate() [*c]Query {
    return gst_query_new_custom(c.GST_QUERY_BITRATE, c.gst_structure_new_static_str_empty("GstQueryBitrate"));
}

pub export fn gst_query_set_bitrate(q: [*c]Query, nominal: c.guint) void {
    if (!is("gst_query_set_bitrate", q, c.GST_QUERY_BITRATE, "GST_QUERY_BITRATE")) return;
    fields.set(structureOf(q), "nominal-bitrate", c.G_TYPE_UINT, nominal);
}

pub export fn gst_query_parse_bitrate(q: [*c]Query, nominal: [*c]c.guint) void {
    if (!is("gst_query_parse_bitrate", q, c.GST_QUERY_BITRATE, "GST_QUERY_BITRATE")) return;
    if (nominal != null) nominal.* = c.g_value_get_uint(value(q, "nominal-bitrate"));
}

pub export fn gst_query_new_selectable() [*c]Query {
    return gst_query_new_custom(c.GST_QUERY_SELECTABLE, c.gst_structure_new_static_str_empty("GstQuerySelectable"));
}

pub export fn gst_query_set_selectable(q: [*c]Query, selectable: c.gboolean) void {
    if (!is("gst_query_set_selectable", q, c.GST_QUERY_SELECTABLE, "GST_QUERY_SELECTABLE")) return;
    fields.set(structureOf(q), "selectable", c.G_TYPE_BOOLEAN, selectable);
}

pub export fn gst_query_parse_selectable(q: [*c]Query, selectable: [*c]c.gboolean) void {
    if (!is("gst_query_parse_selectable", q, c.GST_QUERY_SELECTABLE, "GST_QUERY_SELECTABLE")) return;
    if (selectable == null) return;
    const v = value(q, "selectable");
    selectable.* = if (v != null) c.g_value_get_boolean(v) else 0;
}

pub export fn gst_query_ref(q: [*c]Query) [*c]Query {
    return @ptrCast(mini.gst_mini_object_ref(asMini(q)));
}

pub export fn gst_query_unref(q: [*c]Query) void {
    mini.gst_mini_object_unref(asMini(q));
}

pub export fn gst_clear_query(slot: [*c][*c]Query) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_query_copy(q: [*c]const Query) [*c]Query {
    return @ptrCast(mini.gst_mini_object_copy(asMini(q)));
}

pub export fn gst_query_replace(slot: [*c][*c]Query, q: [*c]Query) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(q));
}

pub export fn gst_query_take(slot: [*c][*c]Query, q: [*c]Query) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(q));
}

pub export fn gst_query_is_writable(q: [*c]const Query) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(q));
}

pub export fn gst_query_make_writable(q: [*c]Query) [*c]Query {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(q)));
}

pub export fn gst_query_steal(slot: [*c][*c]Query) [*c]Query {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}
