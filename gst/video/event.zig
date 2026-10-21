const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Event = c.GstEvent;
const NONE = @as(?*anyopaque, null);
const STILL = "GstEventStillFrame";
const FKU = "GstForceKeyUnit";
const NONE_TIME: c.GstClockTime = c.GST_CLOCK_TIME_NONE;

fn named(e: [*c]Event, name: [*:0]const u8) ?*const c.GstStructure {
    const s = c.gst_event_get_structure(e);
    if (s == null or c.gst_structure_has_name(s, name) == 0) return null;
    return s;
}

pub export fn gst_video_event_new_still_frame(in_still: c.gboolean) [*c]Event {
    const s = c.gst_structure_new(STILL, "still-state", c.G_TYPE_BOOLEAN, in_still, NONE);
    return c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, s);
}

pub export fn gst_video_event_parse_still_frame(e: [*c]Event, in_still: [*c]c.gboolean) c.gboolean {
    if (!check.that(e != null, "gst_video_event_parse_still_frame", "event != NULL")) return 0;
    if (e[0].type != c.GST_EVENT_CUSTOM_DOWNSTREAM) return 0;
    const s = named(e, STILL) orelse return 0;
    var v: c.gboolean = 0;
    if (c.gst_structure_get_boolean(s, "still-state", &v) == 0) return 0;
    if (in_still != null) in_still.* = v;
    return 1;
}

pub export fn gst_video_event_new_downstream_force_key_unit(timestamp: c.GstClockTime, stream_time: c.GstClockTime, running_time: c.GstClockTime, all_headers: c.gboolean, count: c.guint) [*c]Event {
    const s = c.gst_structure_new(FKU, "timestamp", c.G_TYPE_UINT64, timestamp, "stream-time", c.G_TYPE_UINT64, stream_time, "running-time", c.G_TYPE_UINT64, running_time, "all-headers", c.G_TYPE_BOOLEAN, all_headers, "count", c.G_TYPE_UINT, count, NONE);
    return c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, s);
}

pub export fn gst_video_event_new_upstream_force_key_unit(running_time: c.GstClockTime, all_headers: c.gboolean, count: c.guint) [*c]Event {
    const s = c.gst_structure_new(FKU, "running-time", c.G_TYPE_UINT64, running_time, "all-headers", c.G_TYPE_BOOLEAN, all_headers, "count", c.G_TYPE_UINT, count, NONE);
    return c.gst_event_new_custom(c.GST_EVENT_CUSTOM_UPSTREAM, s);
}

pub export fn gst_video_event_is_force_key_unit(e: [*c]Event) c.gboolean {
    if (!check.that(e != null, "gst_video_event_is_force_key_unit", "event != NULL")) return 0;
    if (e[0].type != c.GST_EVENT_CUSTOM_DOWNSTREAM and e[0].type != c.GST_EVENT_CUSTOM_UPSTREAM) return 0;
    return @intFromBool(named(e, FKU) != null);
}

const Common = struct { running: c.GstClockTime, all: c.gboolean, count: c.guint };

fn common(s: ?*const c.GstStructure) Common {
    var r = Common{ .running = NONE_TIME, .all = 0, .count = 0 };
    if (c.gst_structure_get_clock_time(s, "running-time", &r.running) == 0) r.running = NONE_TIME;
    if (c.gst_structure_get_boolean(s, "all-headers", &r.all) == 0) r.all = 0;
    if (c.gst_structure_get_uint(s, "count", &r.count) == 0) r.count = 0;
    return r;
}

fn adjust(e: [*c]Event, out: [*c]c.GstClockTime, v: c.GstClockTime) void {
    const off = c.gst_event_get_running_time_offset(e);
    const neg: u64 = @bitCast(-%off);
    out.* = if (v > neg) v +% @as(u64, @bitCast(off)) else 0;
}

pub export fn gst_video_event_parse_downstream_force_key_unit(e: [*c]Event, timestamp: [*c]c.GstClockTime, stream_time: [*c]c.GstClockTime, running_time: [*c]c.GstClockTime, all_headers: [*c]c.gboolean, count: [*c]c.guint) c.gboolean {
    if (!check.that(e != null, "gst_video_event_parse_downstream_force_key_unit", "event != NULL")) return 0;
    if (e[0].type != c.GST_EVENT_CUSTOM_DOWNSTREAM) return 0;
    const s = named(e, FKU) orelse return 0;
    var ts: c.GstClockTime = NONE_TIME;
    var st: c.GstClockTime = NONE_TIME;
    if (c.gst_structure_get_clock_time(s, "timestamp", &ts) == 0) ts = NONE_TIME;
    if (c.gst_structure_get_clock_time(s, "stream-time", &st) == 0) st = NONE_TIME;
    const r = common(s);
    if (timestamp != null) timestamp.* = ts;
    if (stream_time != null) stream_time.* = st;
    if (running_time != null) adjust(e, running_time, r.running);
    if (all_headers != null) all_headers.* = r.all;
    if (count != null) count.* = r.count;
    return 1;
}

pub export fn gst_video_event_parse_upstream_force_key_unit(e: [*c]Event, running_time: [*c]c.GstClockTime, all_headers: [*c]c.gboolean, count: [*c]c.guint) c.gboolean {
    if (!check.that(e != null, "gst_video_event_parse_upstream_force_key_unit", "event != NULL")) return 0;
    if (e[0].type != c.GST_EVENT_CUSTOM_UPSTREAM) return 0;
    const s = named(e, FKU) orelse return 0;
    const r = common(s);
    if (running_time != null) adjust(e, running_time, r.running);
    if (all_headers != null) all_headers.* = r.all;
    if (count != null) count.* = r.count;
    return 1;
}
