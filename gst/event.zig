const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const fields = @import("fields.zig");
const util = @import("util.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Event = c.GstEvent;
const Mini = c.GstMiniObject;
const Structure = c.GstStructure;
const NONE: u64 = std.math.maxInt(u64);
const CLOCK_TIME = c.G_TYPE_UINT64;

const Impl = extern struct {
    event: Event,
    s: [*c]Structure,
    offset: c.gint64,
};

pub export var _gst_event_type: c.GType = 0;
var type_once: gtype.Once = .{};

const Name = struct { t: c.GstEventType, name: [:0]const u8 };

const names = [_]Name{
    .{ .t = c.GST_EVENT_UNKNOWN, .name = "unknown" },
    .{ .t = c.GST_EVENT_FLUSH_START, .name = "flush-start" },
    .{ .t = c.GST_EVENT_FLUSH_STOP, .name = "flush-stop" },
    .{ .t = c.GST_EVENT_SELECT_STREAMS, .name = "select-streams" },
    .{ .t = c.GST_EVENT_STREAM_START, .name = "stream-start" },
    .{ .t = c.GST_EVENT_STREAM_COLLECTION, .name = "stream-collection" },
    .{ .t = c.GST_EVENT_CAPS, .name = "caps" },
    .{ .t = c.GST_EVENT_SEGMENT, .name = "segment" },
    .{ .t = c.GST_EVENT_TAG, .name = "tag" },
    .{ .t = c.GST_EVENT_TOC, .name = "toc" },
    .{ .t = c.GST_EVENT_PROTECTION, .name = "protection" },
    .{ .t = c.GST_EVENT_BUFFERSIZE, .name = "buffersize" },
    .{ .t = c.GST_EVENT_SINK_MESSAGE, .name = "sink-message" },
    .{ .t = c.GST_EVENT_EOS, .name = "eos" },
    .{ .t = c.GST_EVENT_SEGMENT_DONE, .name = "segment-done" },
    .{ .t = c.GST_EVENT_GAP, .name = "gap" },
    .{ .t = c.GST_EVENT_QOS, .name = "qos" },
    .{ .t = c.GST_EVENT_SEEK, .name = "seek" },
    .{ .t = c.GST_EVENT_NAVIGATION, .name = "navigation" },
    .{ .t = c.GST_EVENT_LATENCY, .name = "latency" },
    .{ .t = c.GST_EVENT_STEP, .name = "step" },
    .{ .t = c.GST_EVENT_RECONFIGURE, .name = "reconfigure" },
    .{ .t = c.GST_EVENT_TOC_SELECT, .name = "toc-select" },
    .{ .t = c.GST_EVENT_CUSTOM_UPSTREAM, .name = "custom-upstream" },
    .{ .t = c.GST_EVENT_CUSTOM_DOWNSTREAM, .name = "custom-downstream" },
    .{ .t = c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB, .name = "custom-downstream-oob" },
    .{ .t = c.GST_EVENT_CUSTOM_DOWNSTREAM_STICKY, .name = "custom-downstream-sticky" },
    .{ .t = c.GST_EVENT_CUSTOM_BOTH, .name = "custom-both" },
    .{ .t = c.GST_EVENT_CUSTOM_BOTH_OOB, .name = "custom-both-oob" },
    .{ .t = c.GST_EVENT_STREAM_GROUP_DONE, .name = "stream-group-done" },
    .{ .t = c.GST_EVENT_INSTANT_RATE_CHANGE, .name = "instant-rate-change" },
    .{ .t = c.GST_EVENT_INSTANT_RATE_SYNC_TIME, .name = "instant-rate-sync-time" },
};

var quarks: [names.len]c.GQuark = .{0} ** names.len;

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub fn isEvent(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_event_type;
}

fn kind(p: anytype) c.GstEventType {
    return impl(p).event.type;
}

fn structureOf(p: anytype) [*c]Structure {
    return impl(p).s;
}

pub export fn gst_event_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstEvent", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    _gst_event_type = gst_event_get_type();
    _ = c.g_type_class_ref(c.gst_seek_flags_get_type());
    _ = c.g_type_class_ref(c.gst_seek_type_get_type());
    for (names, 0..) |n, i| quarks[i] = c.g_quark_from_static_string(n.name.ptr);
}

pub export fn gst_event_type_get_name(t: c.GstEventType) [*c]const u8 {
    for (names) |n| if (n.t == t) return n.name.ptr;
    return "unknown";
}

pub export fn gst_event_type_to_quark(t: c.GstEventType) c.GQuark {
    for (names, 0..) |n, i| if (n.t == t) return quarks[i];
    return 0;
}

pub export fn gst_event_type_get_flags(t: c.GstEventType) c.GstEventTypeFlags {
    return t & ((1 << c.GST_EVENT_NUM_SHIFT) - 1);
}

pub export fn gst_event_type_to_sticky_ordering(t: c.GstEventType) c.guint {
    if (t == c.GST_EVENT_INSTANT_RATE_CHANGE) return c.GST_EVENT_SEGMENT + 1;
    return t;
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    if (!check.that(m != null, "_gst_event_free", "event != NULL")) return;
    if (!check.that(isEvent(m), "_gst_event_free", "GST_IS_EVENT (event)")) return;
    const s = structureOf(m);
    if (s != null) {
        _ = c.gst_structure_set_parent_refcount(s, null);
        c.gst_structure_free(s);
    }
    c.g_free(m);
}

fn setup(e: *Impl, t: c.GstEventType) void {
    mini.gst_mini_object_init(asMini(e), 0, _gst_event_type, copyHook, null, freeHook);
    e.event.type = t;
    e.event.timestamp = NONE;
    e.event.seqnum = util.gst_util_seqnum_next();
    e.offset = 0;
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const s = impl(src);
    const out: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    setup(out, s.event.type);
    out.event.timestamp = s.event.timestamp;
    out.event.seqnum = s.event.seqnum;
    if (s.s != null) {
        out.s = c.gst_structure_copy(s.s);
        _ = c.gst_structure_set_parent_refcount(out.s, &out.event.mini_object.refcount);
    }
    out.offset = s.offset;
    return asMini(out);
}

pub export fn gst_event_new_custom(t: c.GstEventType, s: [*c]Structure) [*c]Event {
    const e: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    if (s != null and c.gst_structure_set_parent_refcount(s, &e.event.mini_object.refcount) == 0) {
        c.g_free(e);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "structure is already owned by another object");
        return null;
    }
    setup(e, t);
    e.s = s;
    return @ptrCast(e);
}

fn guard(comptime f: []const u8, e: [*c]Event) bool {
    return check.that(isEvent(e), f, "GST_IS_EVENT (event)");
}

fn guardType(comptime f: []const u8, e: [*c]Event, t: c.GstEventType, comptime expr: []const u8) bool {
    if (!check.that(isEvent(e), f, "GST_IS_EVENT (event)")) return false;
    return check.that(kind(e) == t, f, expr);
}

fn guardNotNull(comptime f: []const u8, e: [*c]Event, t: c.GstEventType, comptime expr: []const u8) bool {
    if (!check.that(e != null, f, "event != NULL")) return false;
    return check.that(kind(e) == t, f, expr);
}

pub export fn gst_event_get_structure(e: [*c]Event) [*c]const Structure {
    if (!guard("gst_event_get_structure", e)) return null;
    return structureOf(e);
}

pub export fn gst_event_writable_structure(e: [*c]Event) [*c]Structure {
    if (!guard("gst_event_writable_structure", e)) return null;
    if (!check.that(gst_event_is_writable(e) != 0, "gst_event_writable_structure", "gst_event_is_writable (event)")) return null;
    if (impl(e).s == null) {
        const s = c.gst_structure_new_static_str_empty(gst_event_type_get_name(kind(e)));
        _ = c.gst_structure_set_parent_refcount(s, &e[0].mini_object.refcount);
        impl(e).s = s;
    }
    return impl(e).s;
}

pub export fn gst_event_has_name(e: [*c]Event, name: [*c]const u8) c.gboolean {
    if (!guard("gst_event_has_name", e)) return 0;
    if (structureOf(e) == null) return 0;
    return c.gst_structure_has_name(structureOf(e), name);
}

pub export fn gst_event_has_name_id(e: [*c]Event, name: c.GQuark) c.gboolean {
    return gst_event_has_name(e, c.g_quark_to_string(name));
}

pub export fn gst_event_get_seqnum(e: [*c]Event) c.guint32 {
    if (!guard("gst_event_get_seqnum", e)) return std.math.maxInt(u32);
    return e[0].seqnum;
}

pub export fn gst_event_set_seqnum(e: [*c]Event, seqnum: c.guint32) void {
    if (!guard("gst_event_set_seqnum", e)) return;
    if (!check.that(seqnum != c.GST_SEQNUM_INVALID, "gst_event_set_seqnum", "seqnum != GST_SEQNUM_INVALID")) return;
    if (!check.that(gst_event_is_writable(e) != 0, "gst_event_set_seqnum", "gst_event_is_writable (event)")) return;
    e[0].seqnum = seqnum;
}

pub export fn gst_event_get_running_time_offset(e: [*c]Event) c.gint64 {
    if (!guard("gst_event_get_running_time_offset", e)) return 0;
    return impl(e).offset;
}

pub export fn gst_event_set_running_time_offset(e: [*c]Event, offset: c.gint64) void {
    if (!guard("gst_event_set_running_time_offset", e)) return;
    if (!check.that(gst_event_is_writable(e) != 0, "gst_event_set_running_time_offset", "gst_event_is_writable (event)")) return;
    impl(e).offset = offset;
}

fn value(e: anytype, name: [*c]const u8) [*c]const c.GValue {
    return c.gst_structure_get_value(structureOf(e), name);
}

pub export fn gst_event_new_flush_start() [*c]Event {
    return gst_event_new_custom(c.GST_EVENT_FLUSH_START, null);
}

pub export fn gst_event_new_flush_stop(reset: c.gboolean) [*c]Event {
    const s = c.gst_structure_new_static_str_empty("GstEventFlushStop");
    fields.set(s, "reset-time", c.G_TYPE_BOOLEAN, reset);
    return gst_event_new_custom(c.GST_EVENT_FLUSH_STOP, s);
}

pub export fn gst_event_parse_flush_stop(e: [*c]Event, reset: [*c]c.gboolean) void {
    if (!guardType("gst_event_parse_flush_stop", e, c.GST_EVENT_FLUSH_STOP, "GST_EVENT_TYPE (event) == GST_EVENT_FLUSH_STOP")) return;
    if (reset != null) reset.* = c.g_value_get_boolean(value(e, "reset-time"));
}

pub export fn gst_event_new_select_streams(streams: [*c]c.GList) [*c]Event {
    if (!check.that(streams != null, "gst_event_new_select_streams", "streams != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventSelectStreams");
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var node: ?*c.GList = streams;
    while (node) |n| : (node = n.next) {
        var str = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&str, c.G_TYPE_STRING);
        c.g_value_set_string(&str, @ptrCast(n.data));
        c.gst_value_list_append_and_take_value(&list, &str);
    }
    c.gst_structure_take_value(s, "streams", &list);
    return gst_event_new_custom(c.GST_EVENT_SELECT_STREAMS, s);
}

pub export fn gst_event_parse_select_streams(e: [*c]Event, out: [*c][*c]c.GList) void {
    if (!guardType("gst_event_parse_select_streams", e, c.GST_EVENT_SELECT_STREAMS, "GST_EVENT_TYPE (event) == GST_EVENT_SELECT_STREAMS")) return;
    if (out == null) return;
    const list = value(e, "streams");
    var res: [*c]c.GList = null;
    var i: c.guint = 0;
    while (i < c.gst_value_list_get_size(list)) : (i += 1) res = c.g_list_append(res, c.g_value_dup_string(c.gst_value_list_get_value(list, i)));
    out.* = res;
}

pub export fn gst_event_new_stream_group_done(group: c.guint) [*c]Event {
    if (!check.that(group != c.GST_GROUP_ID_INVALID, "gst_event_new_stream_group_done", "group_id != GST_GROUP_ID_INVALID")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventStreamGroupDone");
    fields.set(s, "group-id", c.G_TYPE_UINT, group);
    return gst_event_new_custom(c.GST_EVENT_STREAM_GROUP_DONE, s);
}

pub export fn gst_event_parse_stream_group_done(e: [*c]Event, group: [*c]c.guint) void {
    if (!guardNotNull("gst_event_parse_stream_group_done", e, c.GST_EVENT_STREAM_GROUP_DONE, "GST_EVENT_TYPE (event) == GST_EVENT_STREAM_GROUP_DONE")) return;
    if (group != null) _ = c.gst_structure_get(structureOf(e), "group-id", c.G_TYPE_UINT, group, @as(?*anyopaque, null));
}

pub export fn gst_event_new_eos() [*c]Event {
    return gst_event_new_custom(c.GST_EVENT_EOS, null);
}

pub export fn gst_event_new_gap(ts: c.GstClockTime, duration: c.GstClockTime) [*c]Event {
    if (!check.that(ts != NONE, "gst_event_new_gap", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventGap");
    fields.set(s, "timestamp", CLOCK_TIME, ts);
    fields.set(s, "duration", CLOCK_TIME, duration);
    return gst_event_new_custom(c.GST_EVENT_GAP, s);
}

pub export fn gst_event_parse_gap(e: [*c]Event, ts: [*c]c.GstClockTime, duration: [*c]c.GstClockTime) void {
    if (!guardType("gst_event_parse_gap", e, c.GST_EVENT_GAP, "GST_EVENT_TYPE (event) == GST_EVENT_GAP")) return;
    _ = c.gst_structure_get(structureOf(e), "timestamp", CLOCK_TIME, ts, "duration", CLOCK_TIME, duration, @as(?*anyopaque, null));
}

pub export fn gst_event_set_gap_flags(e: [*c]Event, flags: c.GstGapFlags) void {
    if (!guardNotNull("gst_event_set_gap_flags", e, c.GST_EVENT_GAP, "GST_EVENT_TYPE (event) == GST_EVENT_GAP")) return;
    if (!check.that(gst_event_is_writable(e) != 0, "gst_event_set_gap_flags", "gst_event_is_writable (event)")) return;
    fields.set(structureOf(e), "gap-flags", c.gst_gap_flags_get_type(), flags);
}

pub export fn gst_event_parse_gap_flags(e: [*c]Event, flags: [*c]c.GstGapFlags) void {
    if (!guardNotNull("gst_event_parse_gap_flags", e, c.GST_EVENT_GAP, "GST_EVENT_TYPE (event) == GST_EVENT_GAP")) return;
    if (flags != null) flags.* = 0;
    _ = c.gst_structure_get(structureOf(e), "gap-flags", c.gst_gap_flags_get_type(), flags, @as(?*anyopaque, null));
}

pub export fn gst_event_new_caps(caps: [*c]c.GstCaps) [*c]Event {
    if (!check.that(caps != null, "gst_event_new_caps", "caps != NULL")) return null;
    if (!check.that(c.gst_caps_is_fixed(caps) != 0, "gst_event_new_caps", "gst_caps_is_fixed (caps)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventCaps");
    fields.set(s, "caps", c.gst_caps_get_type(), caps);
    return gst_event_new_custom(c.GST_EVENT_CAPS, s);
}

pub export fn gst_event_parse_caps(e: [*c]Event, caps: [*c][*c]c.GstCaps) void {
    if (!guardType("gst_event_parse_caps", e, c.GST_EVENT_CAPS, "GST_EVENT_TYPE (event) == GST_EVENT_CAPS")) return;
    if (caps != null) caps.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(e, "caps"))));
}

pub export fn gst_event_new_segment(seg: [*c]const c.GstSegment) [*c]Event {
    const f = "gst_event_new_segment";
    if (!check.that(seg != null, f, "segment != NULL")) return null;
    if (!check.that(seg[0].rate != 0.0, f, "segment->rate != 0.0")) return null;
    if (!check.that(seg[0].applied_rate != 0.0, f, "segment->applied_rate != 0.0")) return null;
    if (!check.that(seg[0].format != c.GST_FORMAT_UNDEFINED, f, "segment->format != GST_FORMAT_UNDEFINED")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventSegment");
    fields.set(s, "segment", c.gst_segment_get_type(), seg);
    return gst_event_new_custom(c.GST_EVENT_SEGMENT, s);
}

pub export fn gst_event_parse_segment(e: [*c]Event, seg: [*c][*c]const c.GstSegment) void {
    if (!guardType("gst_event_parse_segment", e, c.GST_EVENT_SEGMENT, "GST_EVENT_TYPE (event) == GST_EVENT_SEGMENT")) return;
    if (seg != null) seg.* = @ptrCast(@alignCast(c.g_value_get_boxed(value(e, "segment"))));
}

pub export fn gst_event_copy_segment(e: [*c]Event, seg: [*c]c.GstSegment) void {
    if (!guardType("gst_event_copy_segment", e, c.GST_EVENT_SEGMENT, "GST_EVENT_TYPE (event) == GST_EVENT_SEGMENT")) return;
    if (seg == null) return;
    var src: [*c]const c.GstSegment = null;
    gst_event_parse_segment(e, &src);
    c.gst_segment_copy_into(src, seg);
}

pub export fn gst_event_new_tag(tags: [*c]c.GstTagList) [*c]Event {
    if (!check.that(tags != null, "gst_event_new_tag", "taglist != NULL")) return null;
    const name: [*c]const u8 = if (c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_GLOBAL) "GstTagList-global" else "GstTagList-stream";
    const s = c.gst_structure_new_static_str_empty(name);
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_tag_list_get_type());
    c.g_value_take_boxed(&v, tags);
    c.gst_structure_take_value(s, "taglist", &v);
    return gst_event_new_custom(c.GST_EVENT_TAG, s);
}

pub export fn gst_event_parse_tag(e: [*c]Event, tags: [*c][*c]c.GstTagList) void {
    if (!guardType("gst_event_parse_tag", e, c.GST_EVENT_TAG, "GST_EVENT_TYPE (event) == GST_EVENT_TAG")) return;
    const v = value(e, "taglist");
    if (tags != null) tags.* = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
}

pub export fn gst_event_new_buffer_size(format: c.GstFormat, min: c.gint64, max: c.gint64, is_async: c.gboolean) [*c]Event {
    const s = c.gst_structure_new_static_str_empty("GstEventBufferSize");
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "minsize", c.G_TYPE_INT64, min);
    fields.set(s, "maxsize", c.G_TYPE_INT64, max);
    fields.set(s, "async", c.G_TYPE_BOOLEAN, is_async);
    return gst_event_new_custom(c.GST_EVENT_BUFFERSIZE, s);
}

pub export fn gst_event_parse_buffer_size(e: [*c]Event, format: [*c]c.GstFormat, min: [*c]c.gint64, max: [*c]c.gint64, is_async: [*c]c.gboolean) void {
    if (!guardType("gst_event_parse_buffer_size", e, c.GST_EVENT_BUFFERSIZE, "GST_EVENT_TYPE (event) == GST_EVENT_BUFFERSIZE")) return;
    if (format != null) format.* = @intCast(c.g_value_get_enum(value(e, "format")));
    if (min != null) min.* = c.g_value_get_int64(value(e, "minsize"));
    if (max != null) max.* = c.g_value_get_int64(value(e, "maxsize"));
    if (is_async != null) is_async.* = c.g_value_get_boolean(value(e, "async"));
}

pub export fn gst_event_new_qos(qos: c.GstQOSType, proportion: c.gdouble, diff: c.GstClockTimeDiff, ts: c.GstClockTime) [*c]Event {
    if (!check.that(diff >= 0 or @as(u64, @bitCast(-%diff)) <= ts, "gst_event_new_qos", "diff >= 0 || -diff <= timestamp")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventQOS");
    fields.set(s, "type", c.gst_qos_type_get_type(), qos);
    fields.set(s, "proportion", c.G_TYPE_DOUBLE, proportion);
    fields.set(s, "diff", c.G_TYPE_INT64, diff);
    fields.set(s, "timestamp", c.G_TYPE_UINT64, ts);
    return gst_event_new_custom(c.GST_EVENT_QOS, s);
}

pub export fn gst_event_parse_qos(e: [*c]Event, qos: [*c]c.GstQOSType, proportion: [*c]c.gdouble, diff: [*c]c.GstClockTimeDiff, ts: [*c]c.GstClockTime) void {
    if (!guardType("gst_event_parse_qos", e, c.GST_EVENT_QOS, "GST_EVENT_TYPE (event) == GST_EVENT_QOS")) return;
    if (qos != null) qos.* = @intCast(c.g_value_get_enum(value(e, "type")));
    if (proportion != null) proportion.* = c.g_value_get_double(value(e, "proportion"));
    if (diff != null) diff.* = c.g_value_get_int64(value(e, "diff"));
    if (ts != null) {
        const offset = gst_event_get_running_time_offset(e);
        const d = c.g_value_get_int64(value(e, "diff"));
        var t = c.g_value_get_uint64(value(e, "timestamp"));
        const neg: u64 = @bitCast(-%offset);
        t = if (t > neg) t +% @as(u64, @bitCast(offset)) else 0;
        if (d < 0 and t < @as(u64, @bitCast(-%d))) t = @bitCast(-%d);
        ts.* = t;
    }
}

pub export fn gst_event_new_seek(rate: c.gdouble, format: c.GstFormat, flags_in: c.GstSeekFlags, start_type: c.GstSeekType, start: c.gint64, stop_type: c.GstSeekType, stop: c.gint64) [*c]Event {
    const f = "gst_event_new_seek";
    if (!check.that(rate != 0.0, f, "rate != 0.0")) return null;
    const instant_ok = flags_in & c.GST_SEEK_FLAG_INSTANT_RATE_CHANGE == 0 or (start_type == c.GST_SEEK_TYPE_NONE and stop_type == c.GST_SEEK_TYPE_NONE and flags_in & c.GST_SEEK_FLAG_FLUSH == 0);
    if (!check.that(instant_ok, f, "(flags & GST_SEEK_FLAG_INSTANT_RATE_CHANGE) == 0 || (start_type == GST_SEEK_TYPE_NONE && stop_type == GST_SEEK_TYPE_NONE && (flags & GST_SEEK_FLAG_FLUSH) == 0)")) return null;
    var flags = flags_in;
    const snap: c.GstSeekFlags = c.GST_SEEK_FLAG_SNAP_BEFORE | c.GST_SEEK_FLAG_SNAP_AFTER | c.GST_SEEK_FLAG_SNAP_NEAREST;
    if (flags & c.GST_SEEK_FLAG_KEY_UNIT == 0 and flags & snap != 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "SNAP seeks only work in combination with the KEY_UNIT flag, ignoring SNAP flags");
        flags &= ~snap;
    }
    const s = c.gst_structure_new_static_str_empty("GstEventSeek");
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "flags", c.gst_seek_flags_get_type(), flags);
    fields.set(s, "cur-type", c.gst_seek_type_get_type(), start_type);
    fields.set(s, "cur", c.G_TYPE_INT64, start);
    fields.set(s, "stop-type", c.gst_seek_type_get_type(), stop_type);
    fields.set(s, "stop", c.G_TYPE_INT64, stop);
    fields.set(s, "trickmode-interval", CLOCK_TIME, @as(u64, 0));
    return gst_event_new_custom(c.GST_EVENT_SEEK, s);
}

pub export fn gst_event_parse_seek(e: [*c]Event, rate: [*c]c.gdouble, format: [*c]c.GstFormat, flags: [*c]c.GstSeekFlags, start_type: [*c]c.GstSeekType, start: [*c]c.gint64, stop_type: [*c]c.GstSeekType, stop: [*c]c.gint64) void {
    if (!guardType("gst_event_parse_seek", e, c.GST_EVENT_SEEK, "GST_EVENT_TYPE (event) == GST_EVENT_SEEK")) return;
    if (rate != null) rate.* = c.g_value_get_double(value(e, "rate"));
    if (format != null) format.* = @intCast(c.g_value_get_enum(value(e, "format")));
    if (flags != null) flags.* = c.g_value_get_flags(value(e, "flags"));
    if (start_type != null) start_type.* = @intCast(c.g_value_get_enum(value(e, "cur-type")));
    if (start != null) start.* = c.g_value_get_int64(value(e, "cur"));
    if (stop_type != null) stop_type.* = @intCast(c.g_value_get_enum(value(e, "stop-type")));
    if (stop != null) stop.* = c.g_value_get_int64(value(e, "stop"));
}

pub export fn gst_event_set_seek_trickmode_interval(e: [*c]Event, interval: c.GstClockTime) void {
    const f = "gst_event_set_seek_trickmode_interval";
    if (!guardNotNull(f, e, c.GST_EVENT_SEEK, "GST_EVENT_TYPE (event) == GST_EVENT_SEEK")) return;
    if (!check.that(gst_event_is_writable(e) != 0, f, "gst_event_is_writable (event)")) return;
    if (!check.that(interval != NONE, f, "GST_CLOCK_TIME_IS_VALID (interval)")) return;
    fields.set(structureOf(e), "trickmode-interval", CLOCK_TIME, interval);
}

pub export fn gst_event_parse_seek_trickmode_interval(e: [*c]Event, interval: [*c]c.GstClockTime) void {
    const f = "gst_event_parse_seek_trickmode_interval";
    if (!check.that(e != null, f, "event != NULL")) return;
    if (!check.that(interval != null, f, "interval != NULL")) return;
    if (!check.that(kind(e) == c.GST_EVENT_SEEK, f, "GST_EVENT_TYPE (event) == GST_EVENT_SEEK")) return;
    interval.* = NONE;
    _ = c.gst_structure_get(structureOf(e), "trickmode-interval", CLOCK_TIME, interval, @as(?*anyopaque, null));
}

pub export fn gst_event_new_navigation(s: [*c]Structure) [*c]Event {
    if (!check.that(s != null, "gst_event_new_navigation", "structure != NULL")) return null;
    return gst_event_new_custom(c.GST_EVENT_NAVIGATION, s);
}

pub export fn gst_event_new_latency(latency: c.GstClockTime) [*c]Event {
    if (!check.that(latency != NONE, "gst_event_new_latency", "GST_CLOCK_TIME_IS_VALID (latency)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventLatency");
    fields.set(s, "latency", c.G_TYPE_UINT64, latency);
    return gst_event_new_custom(c.GST_EVENT_LATENCY, s);
}

pub export fn gst_event_parse_latency(e: [*c]Event, latency: [*c]c.GstClockTime) void {
    if (!guardType("gst_event_parse_latency", e, c.GST_EVENT_LATENCY, "GST_EVENT_TYPE (event) == GST_EVENT_LATENCY")) return;
    if (latency != null) latency.* = c.g_value_get_uint64(value(e, "latency"));
}

pub export fn gst_event_new_step(format: c.GstFormat, amount: c.guint64, rate: c.gdouble, flush: c.gboolean, intermediate: c.gboolean) [*c]Event {
    if (!check.that(rate > 0.0, "gst_event_new_step", "rate > 0.0")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventStep");
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "amount", c.G_TYPE_UINT64, amount);
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "flush", c.G_TYPE_BOOLEAN, flush);
    fields.set(s, "intermediate", c.G_TYPE_BOOLEAN, intermediate);
    return gst_event_new_custom(c.GST_EVENT_STEP, s);
}

pub export fn gst_event_parse_step(e: [*c]Event, format: [*c]c.GstFormat, amount: [*c]c.guint64, rate: [*c]c.gdouble, flush: [*c]c.gboolean, intermediate: [*c]c.gboolean) void {
    if (!guardType("gst_event_parse_step", e, c.GST_EVENT_STEP, "GST_EVENT_TYPE (event) == GST_EVENT_STEP")) return;
    if (format != null) format.* = @intCast(c.g_value_get_enum(value(e, "format")));
    if (amount != null) amount.* = c.g_value_get_uint64(value(e, "amount"));
    if (rate != null) rate.* = c.g_value_get_double(value(e, "rate"));
    if (flush != null) flush.* = c.g_value_get_boolean(value(e, "flush"));
    if (intermediate != null) intermediate.* = c.g_value_get_boolean(value(e, "intermediate"));
}

pub export fn gst_event_new_reconfigure() [*c]Event {
    return gst_event_new_custom(c.GST_EVENT_RECONFIGURE, null);
}

pub export fn gst_event_new_sink_message(name: [*c]const u8, msg: [*c]c.GstMessage) [*c]Event {
    if (!check.that(msg != null, "gst_event_new_sink_message", "msg != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "message", c.gst_message_get_type(), msg);
    return gst_event_new_custom(c.GST_EVENT_SINK_MESSAGE, s);
}

pub export fn gst_event_parse_sink_message(e: [*c]Event, msg: [*c][*c]c.GstMessage) void {
    if (!guardType("gst_event_parse_sink_message", e, c.GST_EVENT_SINK_MESSAGE, "GST_EVENT_TYPE (event) == GST_EVENT_SINK_MESSAGE")) return;
    if (msg != null) msg.* = @ptrCast(@alignCast(c.g_value_dup_boxed(value(e, "message"))));
}

pub export fn gst_event_new_stream_start(id: [*c]const u8) [*c]Event {
    if (!check.that(id != null, "gst_event_new_stream_start", "stream_id != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventStreamStart");
    fields.set(s, "stream-id", c.G_TYPE_STRING, id);
    fields.set(s, "flags", c.gst_stream_flags_get_type(), @as(c.guint, c.GST_STREAM_FLAG_NONE));
    return gst_event_new_custom(c.GST_EVENT_STREAM_START, s);
}

pub export fn gst_event_parse_stream_start(e: [*c]Event, id: [*c][*c]const u8) void {
    if (!guardNotNull("gst_event_parse_stream_start", e, c.GST_EVENT_STREAM_START, "GST_EVENT_TYPE (event) == GST_EVENT_STREAM_START")) return;
    const v = c.gst_structure_get_value(gst_event_get_structure(e), "stream-id");
    if (id != null) id.* = c.g_value_get_string(v);
}

fn startGuard(comptime f: []const u8, e: [*c]Event, comptime write: bool) bool {
    if (!guardNotNull(f, e, c.GST_EVENT_STREAM_START, "GST_EVENT_TYPE (event) == GST_EVENT_STREAM_START")) return false;
    if (write) return check.that(gst_event_is_writable(e) != 0, f, "gst_event_is_writable (event)");
    return true;
}

pub export fn gst_event_set_stream(e: [*c]Event, s: [*c]c.GstStream) void {
    if (!startGuard("gst_event_set_stream", e, true)) return;
    fields.set(structureOf(e), "stream", c.gst_stream_get_type(), s);
}

pub export fn gst_event_parse_stream(e: [*c]Event, s: [*c][*c]c.GstStream) void {
    if (!startGuard("gst_event_parse_stream", e, false)) return;
    if (s == null) return;
    s.* = null;
    _ = c.gst_structure_get(structureOf(e), "stream", c.gst_stream_get_type(), s, @as(?*anyopaque, null));
}

pub export fn gst_event_set_stream_flags(e: [*c]Event, flags: c.GstStreamFlags) void {
    if (!startGuard("gst_event_set_stream_flags", e, true)) return;
    fields.set(structureOf(e), "flags", c.gst_stream_flags_get_type(), flags);
}

pub export fn gst_event_parse_stream_flags(e: [*c]Event, flags: [*c]c.GstStreamFlags) void {
    if (!startGuard("gst_event_parse_stream_flags", e, false)) return;
    if (flags == null) return;
    flags.* = 0;
    _ = c.gst_structure_get(structureOf(e), "flags", c.gst_stream_flags_get_type(), flags, @as(?*anyopaque, null));
}

pub export fn gst_event_set_group_id(e: [*c]Event, group: c.guint) void {
    if (!startGuard("gst_event_set_group_id", e, true)) return;
    if (!check.that(group != c.GST_GROUP_ID_INVALID, "gst_event_set_group_id", "group_id != GST_GROUP_ID_INVALID")) return;
    fields.set(structureOf(e), "group-id", c.G_TYPE_UINT, group);
}

pub export fn gst_event_parse_group_id(e: [*c]Event, group: [*c]c.guint) c.gboolean {
    const f = "gst_event_parse_group_id";
    if (!check.that(e != null, f, "event != NULL")) return 0;
    if (!check.that(kind(e) == c.GST_EVENT_STREAM_START, f, "GST_EVENT_TYPE (event) == GST_EVENT_STREAM_START")) return 0;
    if (group == null) return 1;
    group.* = 0;
    return c.gst_structure_get(structureOf(e), "group-id", c.G_TYPE_UINT, group, @as(?*anyopaque, null));
}

pub export fn gst_event_new_stream_collection(col: [*c]c.GstStreamCollection) [*c]Event {
    if (!check.that(col != null, "gst_event_new_stream_collection", "collection != NULL")) return null;
    if (!check.that(gtype.instanceOf(col, c.gst_stream_collection_get_type()), "gst_event_new_stream_collection", "GST_IS_STREAM_COLLECTION (collection)")) return null;
    const s = c.gst_structure_new_static_str_empty("stream-collection");
    fields.set(s, "collection", c.gst_stream_collection_get_type(), col);
    return gst_event_new_custom(c.GST_EVENT_STREAM_COLLECTION, s);
}

pub export fn gst_event_parse_stream_collection(e: [*c]Event, col: [*c][*c]c.GstStreamCollection) void {
    if (!guardNotNull("gst_event_parse_stream_collection", e, c.GST_EVENT_STREAM_COLLECTION, "GST_EVENT_TYPE (event) == GST_EVENT_STREAM_COLLECTION")) return;
    if (col != null) _ = c.gst_structure_get(gst_event_get_structure(e), "collection", c.gst_stream_collection_get_type(), col, @as(?*anyopaque, null));
}

pub export fn gst_event_new_toc(toc: ?*c.GstToc, updated: c.gboolean) [*c]Event {
    if (!check.that(toc != null, "gst_event_new_toc", "toc != NULL")) return null;
    const name: [*c]const u8 = if (c.gst_toc_get_scope(toc) == c.GST_TOC_SCOPE_GLOBAL) "GstEventTocGlobal" else "GstEventTocCurrent";
    const s = c.gst_structure_new_static_str_empty(name);
    fields.set(s, "toc", c.gst_toc_get_type(), toc);
    fields.set(s, "updated", c.G_TYPE_BOOLEAN, updated);
    return gst_event_new_custom(c.GST_EVENT_TOC, s);
}

pub export fn gst_event_parse_toc(e: [*c]Event, toc: [*c]?*c.GstToc, updated: [*c]c.gboolean) void {
    if (!guardNotNull("gst_event_parse_toc", e, c.GST_EVENT_TOC, "GST_EVENT_TYPE (event) == GST_EVENT_TOC")) return;
    if (!check.that(toc != null, "gst_event_parse_toc", "toc != NULL")) return;
    _ = c.gst_structure_get(gst_event_get_structure(e), "toc", c.gst_toc_get_type(), toc, "updated", c.G_TYPE_BOOLEAN, updated, @as(?*anyopaque, null));
}

pub export fn gst_event_new_toc_select(uid: [*c]const u8) [*c]Event {
    if (!check.that(uid != null, "gst_event_new_toc_select", "uid != NULL")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventTocSelect");
    fields.set(s, "uid", c.G_TYPE_STRING, uid);
    return gst_event_new_custom(c.GST_EVENT_TOC_SELECT, s);
}

pub export fn gst_event_parse_toc_select(e: [*c]Event, uid: [*c][*c]u8) void {
    if (!guardNotNull("gst_event_parse_toc_select", e, c.GST_EVENT_TOC_SELECT, "GST_EVENT_TYPE (event) == GST_EVENT_TOC_SELECT")) return;
    const v = c.gst_structure_get_value(gst_event_get_structure(e), "uid");
    if (uid != null) uid.* = c.g_value_dup_string(v);
}

pub export fn gst_event_new_protection(system: [*c]const u8, data: [*c]c.GstBuffer, origin: [*c]const u8) [*c]Event {
    if (!check.that(system != null, "gst_event_new_protection", "system_id != NULL")) return null;
    if (!check.that(data != null, "gst_event_new_protection", "data != NULL")) return null;
    const name = c.g_strconcat("GstProtectionEvent", @as([*c]const u8, if (origin != null) "-" else ""), @as([*c]const u8, if (origin != null) origin else ""), "-", system, @as(?*anyopaque, null));
    defer c.g_free(name);
    const s = c.gst_structure_new_empty(name);
    fields.set(s, "data", c.gst_buffer_get_type(), data);
    fields.set(s, "system_id", c.G_TYPE_STRING, system);
    if (origin != null) fields.set(s, "origin", c.G_TYPE_STRING, origin);
    return gst_event_new_custom(c.GST_EVENT_PROTECTION, s);
}

pub export fn gst_event_parse_protection(e: [*c]Event, system: [*c][*c]const u8, data: [*c][*c]c.GstBuffer, origin: [*c][*c]const u8) void {
    const f = "gst_event_parse_protection";
    if (!check.that(e != null, f, "event != NULL")) return;
    if (!guardType(f, e, c.GST_EVENT_PROTECTION, "GST_EVENT_TYPE (event) == GST_EVENT_PROTECTION")) return;
    const s = gst_event_get_structure(e);
    if (origin != null) origin.* = c.gst_structure_get_string(s, "origin");
    if (system != null) system.* = c.gst_structure_get_string(s, "system_id");
    if (data != null) data.* = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_structure_get_value(s, "data"))));
}

pub export fn gst_event_new_segment_done(format: c.GstFormat, position: c.gint64) [*c]Event {
    const s = c.gst_structure_new_static_str_empty("GstEventSegmentDone");
    fields.set(s, "format", c.gst_format_get_type(), format);
    fields.set(s, "position", c.G_TYPE_INT64, position);
    return gst_event_new_custom(c.GST_EVENT_SEGMENT_DONE, s);
}

pub export fn gst_event_parse_segment_done(e: [*c]Event, format: [*c]c.GstFormat, position: [*c]c.gint64) void {
    if (!guardNotNull("gst_event_parse_segment_done", e, c.GST_EVENT_SEGMENT_DONE, "GST_EVENT_TYPE (event) == GST_EVENT_SEGMENT_DONE")) return;
    const s = gst_event_get_structure(e);
    if (format != null) format.* = @intCast(c.g_value_get_enum(c.gst_structure_get_value(s, "format")));
    if (position != null) position.* = c.g_value_get_int64(c.gst_structure_get_value(s, "position"));
}

pub export fn gst_event_new_instant_rate_change(rate: c.gdouble, flags: c.GstSegmentFlags) [*c]Event {
    if (!check.that(rate != 0.0, "gst_event_new_instant_rate_change", "rate_multiplier != 0.0")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventInstantRateChange");
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "flags", c.gst_segment_flags_get_type(), flags & c.GST_SEGMENT_INSTANT_FLAGS);
    return gst_event_new_custom(c.GST_EVENT_INSTANT_RATE_CHANGE, s);
}

pub export fn gst_event_parse_instant_rate_change(e: [*c]Event, rate: [*c]c.gdouble, flags: [*c]c.GstSegmentFlags) void {
    if (!guardType("gst_event_parse_instant_rate_change", e, c.GST_EVENT_INSTANT_RATE_CHANGE, "GST_EVENT_TYPE (event) == GST_EVENT_INSTANT_RATE_CHANGE")) return;
    _ = c.gst_structure_get(structureOf(e), "rate", c.G_TYPE_DOUBLE, rate, "flags", c.gst_segment_flags_get_type(), flags, @as(?*anyopaque, null));
}

pub export fn gst_event_new_instant_rate_sync_time(rate: c.gdouble, running: c.GstClockTime, upstream: c.GstClockTime) [*c]Event {
    const f = "gst_event_new_instant_rate_sync_time";
    if (!check.that(rate != 0.0, f, "rate_multiplier != 0.0")) return null;
    if (!check.that(running != NONE, f, "GST_CLOCK_TIME_IS_VALID (running_time)")) return null;
    if (!check.that(upstream != NONE, f, "GST_CLOCK_TIME_IS_VALID (upstream_running_time)")) return null;
    const s = c.gst_structure_new_static_str_empty("GstEventInstantRateSyncTime");
    fields.set(s, "rate", c.G_TYPE_DOUBLE, rate);
    fields.set(s, "running-time", CLOCK_TIME, running);
    fields.set(s, "upstream-running-time", CLOCK_TIME, upstream);
    return gst_event_new_custom(c.GST_EVENT_INSTANT_RATE_SYNC_TIME, s);
}

pub export fn gst_event_parse_instant_rate_sync_time(e: [*c]Event, rate: [*c]c.gdouble, running: [*c]c.GstClockTime, upstream: [*c]c.GstClockTime) void {
    if (!guardType("gst_event_parse_instant_rate_sync_time", e, c.GST_EVENT_INSTANT_RATE_SYNC_TIME, "GST_EVENT_TYPE (event) == GST_EVENT_INSTANT_RATE_SYNC_TIME")) return;
    _ = c.gst_structure_get(structureOf(e), "rate", c.G_TYPE_DOUBLE, rate, "running-time", CLOCK_TIME, running, "upstream-running-time", CLOCK_TIME, upstream, @as(?*anyopaque, null));
}

pub export fn gst_event_replace(slot: [*c][*c]Event, e: [*c]Event) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(e));
}

pub export fn gst_event_steal(slot: [*c][*c]Event) [*c]Event {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_event_take(slot: [*c][*c]Event, e: [*c]Event) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(e));
}

pub export fn gst_event_ref(e: [*c]Event) [*c]Event {
    return @ptrCast(mini.gst_mini_object_ref(asMini(e)));
}

pub export fn gst_event_unref(e: [*c]Event) void {
    mini.gst_mini_object_unref(asMini(e));
}

pub export fn gst_clear_event(slot: [*c][*c]Event) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_event_copy(e: [*c]const Event) [*c]Event {
    return @ptrCast(mini.gst_mini_object_copy(asMini(e)));
}

pub export fn gst_event_is_writable(e: [*c]const Event) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(e));
}

pub export fn gst_event_make_writable(e: [*c]Event) [*c]Event {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(e)));
}
