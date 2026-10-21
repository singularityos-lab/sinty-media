const c = @import("../c.zig").c;
const check = @import("check.zig");

const NONE: u64 = ~@as(u64, 0);

pub const Status = extern struct {
    queued_bytes: u64 = 0,
    queued_buffers: u64 = 0,
    last_in_running_time: u64 = NONE,
    last_out_running_time: u64 = NONE,
    queued_time: u64 = 0,
    num_events: c.guint = 0,
};

fn isType(o: anytype, t: c.GType) bool {
    const p: ?*const c.GstMiniObject = @ptrCast(@alignCast(o));
    return if (p) |m| m.type == t else false;
}

fn dtsOrPts(b: [*c]c.GstBuffer) u64 {
    return if (b[0].dts != NONE) b[0].dts else b[0].pts;
}

pub fn reset(s: *Status) void {
    s.queued_bytes = 0;
    s.queued_buffers = 0;
    s.queued_time = 0;
    s.num_events = 0;
    s.last_in_running_time = NONE;
    s.last_out_running_time = NONE;
}

pub fn isFull(s: *const Status, max_buffers: u64, max_bytes: u64, max_time: u64) bool {
    return (max_buffers > 0 and s.queued_buffers >= max_buffers) or (max_bytes > 0 and s.queued_bytes >= max_bytes) or (max_time > 0 and s.queued_time >= max_time);
}

pub fn pushEvent(s: *Status) void {
    s.num_events += 1;
}

fn updateTime(s: *Status) void {
    if (s.last_out_running_time == NONE or s.last_in_running_time == NONE) return;
    s.queued_time = if (s.last_out_running_time > s.last_in_running_time) 0 else s.last_in_running_time - s.last_out_running_time;
}

fn clamp(seg: [*c]const c.GstSegment, ts: u64) u64 {
    if (seg[0].stop != NONE and ts > seg[0].stop) return seg[0].stop;
    if (seg[0].start > ts) return seg[0].start;
    return ts;
}

const Measure = struct {
    size: c.guint = 0,
    n: c.guint = 0,
    start: u64 = NONE,
    end: u64 = NONE,
};

fn measure(item: ?*c.GstMiniObject, keep_first: bool) Measure {
    var m = Measure{};
    if (isType(item, c._gst_buffer_type)) {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(item));
        m.size = @truncate(c.gst_buffer_get_size(b));
        m.n = 1;
        m.start = dtsOrPts(b);
        m.end = m.start;
        if (m.end != NONE and b[0].duration != NONE) m.end +%= b[0].duration;
    } else if (isType(item, c._gst_buffer_list_type)) {
        const l: ?*c.GstBufferList = @ptrCast(@alignCast(item));
        m.n = c.gst_buffer_list_length(l);
        var i: c.guint = 0;
        while (i < m.n) : (i += 1) {
            const b = c.gst_buffer_list_get(l, i);
            const ts = dtsOrPts(b);
            m.size +%= @truncate(c.gst_buffer_get_size(b));
            if (ts != NONE) {
                if (keep_first and m.start == NONE) m.start = ts;
                m.end = ts;
                if (b[0].duration != NONE) m.end +%= b[0].duration;
            }
        }
    }
    return m;
}

pub fn push(s: *Status, item: ?*c.GstMiniObject, last: [*c]const c.GstSegment) void {
    if (isType(item, c._gst_event_type)) {
        s.num_events += 1;
        return;
    }
    const m = measure(item, true);
    s.queued_bytes +%= m.size;
    s.queued_buffers +%= m.n;
    if (last[0].format != c.GST_FORMAT_TIME or m.end == NONE) return;
    s.last_in_running_time = c.gst_segment_to_running_time(last, c.GST_FORMAT_TIME, clamp(last, m.end));
    if (s.queued_buffers == 1) s.last_out_running_time = c.gst_segment_to_running_time(last, c.GST_FORMAT_TIME, clamp(last, m.start));
    updateTime(s);
}

pub fn pop(s: *Status, item: ?*c.GstMiniObject, current: [*c]const c.GstSegment, last: [*c]const c.GstSegment) void {
    if (isType(item, c._gst_event_type)) {
        s.num_events -%= 1;
        return;
    }
    const m = measure(item, false);
    s.queued_bytes -%= m.size;
    s.queued_buffers -%= m.n;
    const time_ok = current[0].format == c.GST_FORMAT_TIME or (current[0].format == c.GST_FORMAT_UNDEFINED and last[0].format == c.GST_FORMAT_TIME);
    if (!time_ok or m.end == NONE) return;
    const seg = if (current[0].format == c.GST_FORMAT_TIME) current else last;
    s.last_out_running_time = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, clamp(seg, m.end));
    updateTime(s);
}
