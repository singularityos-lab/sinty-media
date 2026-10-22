const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstqueue2.c";
const DOMAIN = "gstreamer-1.0";
const NONE = cm.CLOCK_NONE;
const SEC: u64 = 1_000_000_000;
const BLOCK = 4096;
const LEVEL_MAX = 1_000_000;
const PERCENT = LEVEL_MAX / 100;
const RATE_INTERVAL = 0.2;

const PROP_CUR_LEVEL_BUFFERS = 1;
const PROP_CUR_LEVEL_BYTES = 2;
const PROP_CUR_LEVEL_TIME = 3;
const PROP_MAX_SIZE_BUFFERS = 4;
const PROP_MAX_SIZE_BYTES = 5;
const PROP_MAX_SIZE_TIME = 6;
const PROP_USE_BUFFERING = 7;
const PROP_USE_TAGS_BITRATE = 8;
const PROP_USE_RATE_ESTIMATE = 9;
const PROP_LOW_PERCENT = 10;
const PROP_HIGH_PERCENT = 11;
const PROP_LOW_WATERMARK = 12;
const PROP_HIGH_WATERMARK = 13;
const PROP_TEMP_TEMPLATE = 14;
const PROP_TEMP_LOCATION = 15;
const PROP_TEMP_REMOVE = 16;
const PROP_RING_BUFFER_MAX_SIZE = 17;
const PROP_AVG_IN_RATE = 18;
const PROP_USE_BITRATE_QUERY = 19;
const PROP_BITRATE = 20;
const PROP_LAST = 21;

const Kind = enum(c_int) { unknown, buffer, list, event, query };

const Item = extern struct {
    kind: Kind,
    item: [*c]c.GstMiniObject,
};

const Size = struct {
    buffers: c.guint = 0,
    bytes: c.guint = 0,
    time: u64 = 0,
    rate_time: u64 = 0,
};

const Range = struct {
    next: ?*Range = null,
    offset: u64,
    rb_offset: u64,
    writing_pos: u64,
    rb_writing_pos: u64,
    reading_pos: u64,
    max_reading_pos: u64,
};

const State = struct {
    upstream_size: u64 = 0,
    sink_segment: c.GstSegment = undefined,
    src_segment: c.GstSegment = undefined,
    sinktime: u64 = NONE,
    srctime: u64 = NONE,
    sink_start_time: u64 = NONE,
    sink_tainted: bool = false,
    src_tainted: bool = false,
    sink_tags_bitrate: c.guint = 0,
    src_tags_bitrate: c.guint = 0,
    srcresult: c.GstFlowReturn = c.GST_FLOW_FLUSHING,
    sinkresult: c.GstFlowReturn = c.GST_FLOW_FLUSHING,
    is_eos: bool = false,
    unexpected: bool = false,
    queue: ?*c.GstVecDeque = null,
    query_handled: c.GCond = undefined,
    last_query: bool = false,
    last_handled_query: [*c]c.GstQuery = null,
    cur: Size = .{},
    max: Size = .{ .buffers = 100, .bytes = 2 * 1024 * 1024, .time = 2 * SEC, .rate_time = 2 * SEC },
    use_buffering: bool = false,
    use_tags_bitrate: bool = false,
    use_bitrate_query: bool = true,
    use_rate_estimate: bool = true,
    downstream_bitrate: c.guint = 0,
    low_watermark: c.gint = 10000,
    high_watermark: c.gint = 990000,
    is_buffering: bool = false,
    buffering_percent: c.gint = 100,
    last_posted_percent: c.gint = -1,
    in_timer: ?*c.GTimer = null,
    in_started: bool = false,
    last_update_in: f64 = 0,
    last_in: f64 = 0,
    bytes_in: u64 = 0,
    in_rate: f64 = 0,
    in_period: f64 = 0,
    out_timer: ?*c.GTimer = null,
    out_started: bool = false,
    last_out: f64 = 0,
    bytes_out: u64 = 0,
    out_rate: f64 = 0,
    qlock: c.GMutex = undefined,
    waiting_add: bool = false,
    item_add: c.GCond = undefined,
    waiting_del: bool = false,
    item_del: c.GCond = undefined,
    temp_template: [*c]u8 = null,
    temp_location: [*c]u8 = null,
    temp_remove: bool = true,
    temp_file: ?*c.FILE = null,
    ranges: ?*Range = null,
    current: ?*Range = null,
    segment_received: bool = false,
    starting_segment: [*c]c.GstEvent = null,
    seeking: bool = false,
    stream_start: [*c]c.GstEvent = null,
    rb_max: u64 = 0,
    ring: ?[*]u8 = null,
    may_block: c.gint = 0,
    mode: c.GstBufferingMode = c.GST_BUFFERING_STREAM,
    left: i64 = 0,
    avg_in: c.gint = 0,
    avg_out: c.gint = 0,
    post_lock: c.GMutex = undefined,
};

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    st: *State,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var props: [PROP_LAST][*c]c.GParamSpec = .{null} ** PROP_LAST;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn notify(q: *Self, id: usize) void {
    c.g_object_notify_by_pspec(@ptrCast(@alignCast(q)), props[id]);
}

fn lockQ(s: *State) void {
    c.g_mutex_lock(&s.qlock);
}

fn unlockQ(s: *State) void {
    c.g_mutex_unlock(&s.qlock);
}

fn usingTemp(s: *State) bool {
    return s.temp_template != null;
}

fn usingRing(s: *State) bool {
    return s.rb_max != 0;
}

fn usingQueue(s: *State) bool {
    return !usingTemp(s) and !usingRing(s);
}

fn maxBytes(s: *State) u64 {
    return @min(@as(u64, s.max.bytes), s.rb_max);
}

fn signalAdd(s: *State) void {
    if (s.waiting_add) c.g_cond_signal(&s.item_add);
}

fn signalDel(s: *State) void {
    if (s.waiting_del) c.g_cond_signal(&s.item_del);
}

fn waitAdd(s: *State) bool {
    if (s.srcresult != c.GST_FLOW_OK) return false;
    s.waiting_add = true;
    c.g_cond_wait(&s.item_add, &s.qlock);
    s.waiting_add = false;
    return s.srcresult == c.GST_FLOW_OK;
}

fn waitDel(s: *State) bool {
    if (s.sinkresult != c.GST_FLOW_OK) return false;
    s.waiting_del = true;
    c.g_cond_wait(&s.item_del, &s.qlock);
    s.waiting_del = false;
    return s.sinkresult == c.GST_FLOW_OK;
}

fn resError(q: *Self, code: c.gint, text: [*c]u8, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(q, c.gst_resource_error_quark(), code, text, dbg, FILE, func, line);
}

fn sysError() [*c]u8 {
    return c.g_strdup_printf("system error: %s", c.g_strerror(std.c._errno().*));
}

fn cleanRanges(s: *State) void {
    var r = s.ranges;
    while (r) |x| {
        r = x.next;
        std.heap.c_allocator.destroy(x);
    }
    s.ranges = null;
    s.current = null;
}

fn findRange(s: *State, off: u64) ?*Range {
    var r = s.ranges;
    while (r) |x| : (r = x.next) {
        if (off >= x.offset and off <= x.writing_pos) return x;
    }
    return null;
}

fn updateCurLevel(s: *State, r: *Range) void {
    s.cur.bytes = if (r.writing_pos > r.max_reading_pos) @truncate(r.writing_pos - r.max_reading_pos) else 0;
}

fn addRange(s: *State, off: u64, update: bool) *Range {
    if (findRange(s, off)) |r| {
        if (update and r.writing_pos != off) r.writing_pos = off;
        updateCurLevel(s, r);
        return r;
    }
    const r = blk: {
        const n = std.heap.c_allocator.create(Range) catch @panic("oom");
        const rb = if (s.current) |cur| cur.rb_writing_pos else 0;
        n.* = .{ .offset = off, .rb_offset = rb, .writing_pos = off, .rb_writing_pos = rb, .reading_pos = off, .max_reading_pos = off };
        var prev: ?*Range = null;
        var next = s.ranges;
        while (next) |x| {
            if (x.offset > off) break;
            prev = x;
            next = x.next;
        }
        n.next = next;
        if (prev) |p| {
            p.next = n;
        } else s.ranges = n;
        break :blk n;
    };
    updateCurLevel(s, r);
    return r;
}

fn initRanges(s: *State) void {
    cleanRanges(s);
    s.current = addRange(s, 0, true);
}

fn updateTimeLevel(s: *State) void {
    if (s.sink_tainted) {
        s.sinktime = c.gst_segment_to_running_time(&s.sink_segment, c.GST_FORMAT_TIME, s.sink_segment.position);
        s.sink_tainted = false;
    }
    if (s.src_tainted) {
        s.srctime = c.gst_segment_to_running_time(&s.src_segment, c.GST_FORMAT_TIME, s.src_segment.position);
        s.src_tainted = false;
    }
    s.cur.time = 0;
    if (s.sinktime == NONE) return;
    if (s.srctime == NONE and s.sink_start_time != NONE and s.sinktime >= s.sink_start_time) {
        s.cur.time = s.sinktime - s.sink_start_time;
    } else if (s.srctime != NONE and s.sinktime >= s.srctime) s.cur.time = s.sinktime - s.srctime;
}

fn applySegment(s: *State, ev: [*c]c.GstEvent, seg: *c.GstSegment, sink: bool) void {
    c.gst_event_copy_segment(ev, seg);
    if (seg.format == c.GST_FORMAT_BYTES and !usingQueue(s) and sink) s.current = addRange(s, seg.start, true);
    if (seg.format != c.GST_FORMAT_TIME) {
        seg.format = c.GST_FORMAT_TIME;
        seg.start = 0;
        seg.stop = NONE;
        seg.time = 0;
    }
    if (sink) {
        s.sink_tainted = false;
    } else s.src_tainted = false;
}

fn moveTo(s: *State, seg: *c.GstSegment, sink: bool, ts: u64) void {
    seg.position = ts;
    if (sink) {
        s.sink_tainted = true;
    } else s.src_tainted = true;
    updateTimeLevel(s);
}

fn applyGap(s: *State, ev: [*c]c.GstEvent, seg: *c.GstSegment, sink: bool) void {
    var ts: u64 = 0;
    var dur: u64 = 0;
    c.gst_event_parse_gap(ev, &ts, &dur);
    if (!cm.that(ts != NONE, "apply_gap", "GST_CLOCK_TIME_IS_VALID (timestamp)")) return;
    if (sink and s.sink_start_time == NONE) s.sink_start_time = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, ts);
    if (dur != NONE) ts +%= dur;
    moveTo(s, seg, sink, ts);
}

fn scaleBits(size: u64, rate: c.guint) u64 {
    return c.gst_util_uint64_scale(size, 8 * SEC, rate);
}

fn applyBuffer(s: *State, b: [*c]c.GstBuffer, seg: *c.GstSegment, size: u64, sink: bool) void {
    var ts = cm.dtsOrPts(b);
    if (ts == NONE) return;
    var dur = cm.buf(b).duration;
    if (dur == NONE) {
        if (s.use_tags_bitrate) {
            const rate = if (sink) s.sink_tags_bitrate else s.src_tags_bitrate;
            if (rate != 0) dur = scaleBits(size, rate);
        }
        if (dur == NONE and !sink and s.use_bitrate_query and s.downstream_bitrate > 0) dur = scaleBits(size, s.downstream_bitrate);
    }
    if (sink and s.sink_start_time == NONE) s.sink_start_time = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, ts);
    if (dur != NONE) ts +%= dur;
    moveTo(s, seg, sink, ts);
}

fn applyList(s: *State, l: ?*c.GstBufferList, seg: *c.GstSegment, sink: bool) void {
    var rate: c.guint = 0;
    if (s.use_tags_bitrate) rate = if (sink) s.sink_tags_bitrate else s.src_tags_bitrate;
    if (!sink and rate == 0 and s.use_bitrate_query) rate = s.downstream_bitrate;
    var first: u64 = NONE;
    var ts: u64 = NONE;
    var i: c.guint = 0;
    while (i < c.gst_buffer_list_length(l)) : (i += 1) {
        const b = c.gst_buffer_list_get(l, i);
        const t = cm.dtsOrPts(b);
        if (t != NONE) {
            if (first == NONE) first = t;
            ts = t;
        }
        if (cm.buf(b).duration != NONE and ts != NONE) {
            ts +%= cm.buf(b).duration;
        } else if (rate != 0 and ts != NONE) ts +%= c.gst_util_uint64_scale(rate, 8 * SEC, c.gst_buffer_get_size(b));
    }
    if (ts == NONE) return;
    if (sink and s.sink_start_time == NONE and first != NONE) s.sink_start_time = c.gst_segment_to_running_time(seg, c.GST_FORMAT_TIME, first);
    moveTo(s, seg, sink, ts);
}

fn normalize(cur: u64, max: u64, alt: u64) c.gint {
    if (max == 0) return 0;
    const p = c.gst_util_uint64_scale(cur, LEVEL_MAX, if (alt > 0) @min(max, alt) else max);
    return @intCast(@min(p, LEVEL_MAX));
}

fn bufferingLevel(s: *State, buffering: ?*c.gboolean) ?c.gint {
    if (s.high_watermark <= 0) {
        if (buffering) |b| b.* = 0;
        return null;
    }
    var lv: c.gint = LEVEL_MAX;
    if (!s.is_eos and s.srcresult != c.GST_FLOW_NOT_LINKED) {
        lv = normalize(s.cur.bytes, s.max.bytes, if (usingRing(s)) s.rb_max else 0);
        lv = @max(lv, normalize(s.cur.time, s.max.time, 0));
        lv = @max(lv, normalize(s.cur.buffers, s.max.buffers, 0));
        if (s.use_rate_estimate) lv = @max(lv, normalize(s.cur.rate_time, s.max.rate_time, 0));
        if (s.cur.bytes > 0) lv = @max(1, lv);
    }
    if (buffering) |b| b.* = @intFromBool(s.is_buffering);
    return lv;
}

fn toPercent(s: *State, lv: c.gint) c.gint {
    return @min(@divTrunc(lv * 100, s.high_watermark), 100);
}

fn bufferingMode(s: *State) c.GstBufferingMode {
    if (usingQueue(s)) return c.GST_BUFFERING_STREAM;
    return if (usingRing(s)) c.GST_BUFFERING_TIMESHIFT else c.GST_BUFFERING_DOWNLOAD;
}

fn bufferingLeft(s: *State, p: c.gint) i64 {
    var left: i64 = if (p == 100) 0 else -1;
    if (s.use_rate_estimate and p != 100 and s.max.rate_time > s.cur.rate_time) left = @intCast((s.max.rate_time - s.cur.rate_time) / 1_000_000);
    return left;
}

fn setPercent(s: *State, p: c.gint) void {
    if (p == s.buffering_percent) return;
    s.buffering_percent = p;
    s.mode = bufferingMode(s);
    s.avg_in = @intFromFloat(s.in_rate);
    s.avg_out = @intFromFloat(s.out_rate);
    s.left = bufferingLeft(s, p);
}

fn postBuffering(q: *Self) void {
    const s = q.st;
    c.g_mutex_lock(&s.post_lock);
    lockQ(s);
    var msg: [*c]c.GstMessage = null;
    var p: c.gint = -1;
    if ((!s.waiting_del or s.buffering_percent == 100) and s.last_posted_percent != s.buffering_percent) {
        p = s.buffering_percent;
        msg = c.gst_message_new_buffering(cm.obj(q), p);
        c.gst_message_set_buffering_stats(msg, s.mode, s.avg_in, s.avg_out, s.left);
    }
    unlockQ(s);
    if (msg != null and c.gst_element_post_message(element(q), msg) != 0) s.last_posted_percent = p;
    c.g_mutex_unlock(&s.post_lock);
}

fn updateBuffering(s: *State) void {
    if (s.current) |r| updateCurLevel(s, r);
    updateInRates(s, false);
    const lv = bufferingLevel(s, null) orelse return;
    const p = toPercent(s, lv);
    if (s.is_buffering) {
        if (p >= 100) s.is_buffering = false;
        setPercent(s, p);
    } else if (lv < s.low_watermark) {
        s.is_buffering = true;
        setPercent(s, p);
    }
}

fn resetRates(s: *State) void {
    s.bytes_in = 0;
    s.bytes_out = 0;
    s.in_rate = 0;
    s.in_period = 0;
    s.out_rate = 0;
    s.last_update_in = 0;
    s.last_in = 0;
    s.last_out = 0;
    s.in_started = false;
    s.out_started = false;
}

fn rateTime(s: *State) u64 {
    return @intFromFloat(@as(f64, @floatFromInt(s.cur.bytes)) / s.in_rate * @as(f64, @floatFromInt(SEC)));
}

fn updateInRates(s: *State, force: bool) void {
    if (!s.in_started) {
        s.in_started = true;
        c.g_timer_start(s.in_timer);
        return;
    }
    const now = c.g_timer_elapsed(s.in_timer, null);
    s.last_update_in = now;
    if (force or s.last_in + RATE_INTERVAL < now) {
        const period = now - s.last_in;
        const rate = @as(f64, @floatFromInt(s.bytes_in)) / period;
        s.in_rate = if (s.in_rate == 0.0) rate else (s.in_rate * s.in_period + rate * period) / (s.in_period + period);
        if (s.in_period < 16 * RATE_INTERVAL) s.in_period += period;
        s.last_in = now;
        s.bytes_in = 0;
    }
    if (s.use_bitrate_query and s.downstream_bitrate > 0) {
        s.cur.rate_time = c.gst_util_uint64_scale(8 * @as(u64, s.cur.bytes), SEC, s.downstream_bitrate);
    } else if (s.in_rate > 0.0) s.cur.rate_time = rateTime(s);
}

fn updateOutRates(s: *State) void {
    if (!s.out_started) {
        s.out_started = true;
        c.g_timer_start(s.out_timer);
        return;
    }
    const now = c.g_timer_elapsed(s.out_timer, null);
    if (s.last_out + RATE_INTERVAL < now) {
        const period = now - s.last_out;
        const rate = @as(f64, @floatFromInt(s.bytes_out)) / period;
        s.out_rate = if (s.out_rate == 0.0) rate else (s.out_rate * 3.0 + rate) / 4.0;
        s.last_out = now;
        s.bytes_out = 0;
    }
    if (s.in_rate > 0.0) s.cur.rate_time = rateTime(s);
}

fn updateCurPos(s: *State, r: *Range, pos: u64) void {
    r.max_reading_pos = @max(r.max_reading_pos, pos);
    updateCurLevel(s, r);
}

fn seekTo(q: *Self, off: u64) void {
    const s = q.st;
    s.seeking = true;
    unlockQ(s);
    const ok = c.gst_pad_push_event(q.sinkpad, c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH | c.GST_SEEK_FLAG_ACCURATE, c.GST_SEEK_TYPE_SET, @bitCast(off), c.GST_SEEK_TYPE_NONE, -1));
    lockQ(s);
    if (ok != 0) s.current = addRange(s, off, false);
}

fn seekThreshold(s: *State) u64 {
    var t: u64 = 1024 * 512;
    if (usingRing(s)) t = @min(t, maxBytes(s) -% s.cur.bytes);
    return t;
}

fn haveData(q: *Self, off: u64, len: c.guint) bool {
    const s = q.st;
    if (findRange(s, off)) |r| {
        if (s.current != r) seekTo(q, r.writing_pos);
        if (!usingRing(s) and s.is_eos) return true;
        return off + len <= r.writing_pos;
    }
    if (!s.is_eos) {
        if (s.current) |cur| {
            if (off >= cur.offset and off <= cur.writing_pos + seekThreshold(s)) return false;
        }
    }
    seekTo(q, off);
    return false;
}

fn fseekTo(fp: ?*c.FILE, off: u64) bool {
    return c.fseeko(fp, @intCast(off), c.SEEK_SET) == 0;
}

fn readAt(q: *Self, off: u64, len: u64, dst: [*]u8, got: *u64) c.GstFlowReturn {
    const s = q.st;
    if (usingTemp(s) and !fseekTo(s.temp_file, off)) {
        resError(q, c.GST_RESOURCE_ERROR_SEEK, null, sysError(), "gst_queue2_read_data_at_offset", 1552);
        return c.GST_FLOW_ERROR;
    }
    var n: u64 = len;
    if (usingTemp(s)) {
        n = c.fread(dst, 1, len, s.temp_file);
    } else @memcpy(dst[0..len], s.ring.?[off .. off + len]);
    if (n < len) {
        if (!usingTemp(s) or c.ferror(s.temp_file) != 0) {
            resError(q, c.GST_RESOURCE_ERROR_READ, null, sysError(), "gst_queue2_read_data_at_offset", 1557);
            return c.GST_FLOW_ERROR;
        }
        if (c.feof(s.temp_file) != 0 and len > 0) return c.GST_FLOW_EOS;
    }
    got.* = n;
    return c.GST_FLOW_OK;
}

fn createRead(q: *Self, off: u64, len_in: c.guint, out: [*c][*c]c.GstBuffer) c.GstFlowReturn {
    const s = q.st;
    var len = len_in;
    const b = if (out[0] == null) c.gst_buffer_new_allocate(null, len, null) else out[0];
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_WRITE) == 0) {
        resError(q, c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup("Can't write to buffer"), "gst_queue2_create_read", 1741);
        if (out[0] == null) c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    var data: [*]u8 = info.data;
    var rpos = off;
    const rb = s.rb_max;
    const max = maxBytes(s);
    var remaining: u64 = len;
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    var failed: ?c.GstFlowReturn = null;
    outer: while (remaining > 0) {
        var want: u64 = 0;
        if (!haveData(q, rpos, @truncate(remaining))) {
            if (usingRing(s)) {
                const cur = s.current.?;
                const lv = if (cur.writing_pos > rpos) cur.writing_pos - rpos else 0;
                if (lv >= max) {
                    want = max;
                } else if (s.is_eos) {
                    if (lv == 0) {
                        failed = c.GST_FLOW_EOS;
                        break;
                    }
                    want = lv;
                    remaining = lv;
                    len = @truncate(lv);
                }
            }
            if (want == 0) {
                if (usingRing(s)) {
                    updateCurPos(s, s.current.?, rpos);
                    signalDel(s);
                }
                if (s.use_buffering) updateBuffering(s);
                if (!waitAdd(s)) {
                    failed = c.GST_FLOW_FLUSHING;
                    break;
                }
                continue;
            }
        } else want = remaining;
        const cur = s.current.?;
        cur.reading_pos = rpos;
        var foff: u64 = rpos;
        var block = want;
        if (usingRing(s)) {
            foff = (cur.rb_offset + (rpos - cur.offset)) % rb;
            if (foff + want > rb) block = rb - foff;
        }
        while (want > 0) {
            var got: u64 = 0;
            ret = readAt(q, foff, block, data, &got);
            if (ret != c.GST_FLOW_OK) {
                failed = ret;
                break :outer;
            }
            foff += got;
            if (usingRing(s)) foff %= rb;
            data += got;
            want -= got;
            block = want;
            remaining -= got;
            cur.reading_pos += got;
            rpos = cur.reading_pos;
            updateCurPos(s, cur, cur.reading_pos);
        }
        signalDel(s);
    }
    c.gst_buffer_unmap(b, &info);
    if (failed) |f| {
        if (out[0] == null) c.gst_buffer_unref(b);
        return f;
    }
    c.gst_buffer_resize(b, 0, len);
    cm.buf(b).offset = off;
    cm.buf(b).offset_end = off + len;
    out[0] = b;
    return ret;
}

fn readItem(q: *Self) [*c]c.GstMiniObject {
    const s = q.st;
    if (s.stream_start != null) {
        const it: [*c]c.GstMiniObject = @ptrCast(s.stream_start);
        s.stream_start = null;
        return it;
    }
    if (s.starting_segment != null) {
        const it: [*c]c.GstMiniObject = @ptrCast(s.starting_segment);
        s.starting_segment = null;
        return it;
    }
    var b: [*c]c.GstBuffer = null;
    return switch (createRead(q, s.current.?.reading_pos, BLOCK, &b)) {
        c.GST_FLOW_OK => @ptrCast(b),
        c.GST_FLOW_EOS => @ptrCast(c.gst_event_new_eos()),
        else => null,
    };
}

fn openTemp(q: *Self) bool {
    const s = q.st;
    if (s.temp_file != null) return true;
    if (s.temp_template == null) {
        resError(q, c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "No Temp directory specified.")), null, "gst_queue2_open_temp_location_file", 1846);
        return false;
    }
    const name = c.g_strdup(s.temp_template);
    const fd = c.g_mkstemp(name);
    if (fd == -1) {
        resError(q, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not create temp file \"%s\"."), s.temp_template), sysError(), "gst_queue2_open_temp_location_file", 1852);
        c.g_free(name);
        return false;
    }
    s.temp_file = c.fdopen(fd, "wb+");
    if (s.temp_file == null) {
        resError(q, c.GST_RESOURCE_ERROR_OPEN_READ, c.g_strdup_printf(cm.tr(DOMAIN, "Could not open file \"%s\" for reading."), name), sysError(), "gst_queue2_open_temp_location_file", 1860);
        c.g_free(name);
        _ = c.close(fd);
        return false;
    }
    c.g_free(s.temp_location);
    s.temp_location = name;
    unlockQ(s);
    notify(q, PROP_TEMP_LOCATION);
    lockQ(s);
    return true;
}

fn closeTemp(s: *State) void {
    const fp = s.temp_file orelse return;
    _ = c.fflush(fp);
    _ = c.fclose(fp);
    if (s.temp_remove) _ = c.remove(s.temp_location);
    s.temp_file = null;
    cleanRanges(s);
}

fn dropItem(it: *Item) void {
    if (it.kind != .query) c.gst_mini_object_unref(it.item);
}

fn lockedFlush(q: *Self, full: bool, clear_temp: bool) void {
    const s = q.st;
    if (!usingQueue(s)) {
        if (usingTemp(s) and clear_temp and s.temp_file != null) s.temp_file = c.freopen(s.temp_location, "wb+", s.temp_file);
        initRanges(s);
    } else {
        while (@as(?*Item, @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(s.queue))))) |it| {
            if (!full and it.kind == .event and cm.eventSticky(it.item) and cm.eventType(it.item) != c.GST_EVENT_SEGMENT and cm.eventType(it.item) != c.GST_EVENT_EOS) _ = c.gst_pad_store_sticky_event(q.srcpad, @ptrCast(it.item));
            dropItem(it);
        }
    }
    s.last_query = false;
    c.g_cond_signal(&s.query_handled);
    s.cur = .{};
    c.gst_segment_init(&s.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&s.src_segment, c.GST_FORMAT_TIME);
    s.sinktime = NONE;
    s.srctime = NONE;
    s.sink_start_time = NONE;
    s.sink_tainted = false;
    s.src_tainted = false;
    if (s.starting_segment != null) c.gst_mini_object_unref(@ptrCast(s.starting_segment));
    s.starting_segment = null;
    s.segment_received = false;
    _ = c.gst_mini_object_replace(@ptrCast(&s.stream_start), null);
    signalDel(s);
}

fn waitFreeSpace(s: *State) bool {
    if (!isFilled(s)) return true;
    const started = s.in_started;
    if (started) c.g_timer_stop(s.in_timer);
    while (true) {
        if (!waitDel(s)) return false;
        if (!isFilled(s)) break;
    }
    if (started) c.g_timer_continue(s.in_timer);
    return true;
}

fn writeError(q: *Self) void {
    const e = std.c._errno().*;
    if (e == c.ENOSPC) {
        resError(q, c.GST_RESOURCE_ERROR_NO_SPACE_LEFT, null, null, "gst_queue2_create_write", 2270);
    } else resError(q, c.GST_RESOURCE_ERROR_WRITE, c.g_strdup(cm.tr(DOMAIN, "Error while writing to download file.")), c.g_strdup_printf("%s", c.g_strerror(e)), "gst_queue2_create_write", 2274);
}

fn put(q: *Self, at: u64, src: [*]const u8, n: u64) bool {
    const s = q.st;
    if (n == 0) return true;
    if (usingTemp(s)) {
        if (c.fwrite(src, n, 1, s.temp_file) != 1) {
            writeError(q);
            return false;
        }
    } else @memcpy(s.ring.?[at .. at + n], src[0..n]);
    return true;
}

fn trimRanges(s: *State, wpos: u64, newpos: u64, n: u64) void {
    const rb = s.rb_max;
    var prev: ?*Range = null;
    var r = s.ranges;
    while (r) |x| {
        var kill = false;
        if (x != s.current) {
            const start = x.rb_offset;
            const end = x.rb_writing_pos;
            if (x.writing_pos == x.offset) {
                kill = true;
            } else if (end > start) {
                if (!(wpos >= end and newpos >= wpos) and newpos > start) {
                    if (newpos >= end) {
                        kill = true;
                    } else {
                        x.offset += newpos - start;
                        x.rb_offset = newpos;
                    }
                }
            } else {
                const virt = wpos + n;
                if (virt > start) {
                    if (virt > rb and newpos >= end) {
                        kill = true;
                    } else {
                        x.offset += virt - start;
                        x.rb_offset = newpos;
                    }
                }
            }
        }
        r = x.next;
        if (kill) {
            if (prev) |p| p.next = x.next;
            if (s.ranges == x) s.ranges = r;
            std.heap.c_allocator.destroy(x);
        } else prev = x;
    }
}

fn createWrite(q: *Self, b: [*c]c.GstBuffer) bool {
    const s = q.st;
    var info: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(b, &info, c.GST_MAP_READ) == 0) {
        resError(q, c.GST_RESOURCE_ERROR_READ, null, c.g_strdup("Can't read from buffer"), "gst_queue2_create_write", 2284);
        return false;
    }
    defer c.gst_buffer_unmap(b, &info);
    const rb = s.rb_max;
    var wpos = if (usingRing(s)) s.current.?.rb_writing_pos else s.current.?.writing_pos;
    var size: u64 = info.size;
    var data: [*]const u8 = info.data;
    while (size > 0) {
        var n: u64 = size;
        var newpos: u64 = wpos + size;
        var reseek = false;
        if (usingRing(s)) {
            while (maxBytes(s) <= s.cur.bytes) {
                if (!waitDel(s)) return false;
            }
            n = @min(size, maxBytes(s) - s.cur.bytes);
            newpos = (wpos + n) % rb;
            trimRanges(s, wpos, newpos, n);
        }
        if (usingTemp(s) and !fseekTo(s.temp_file, wpos)) {
            resError(q, c.GST_RESOURCE_ERROR_SEEK, null, sysError(), "gst_queue2_create_write", 2262);
            return false;
        }
        if (newpos > wpos) {
            if (!put(q, wpos, data, n)) return false;
            if (!usingRing(s)) {
                const cur = s.current.?;
                while (cur.next) |nx| {
                    if (newpos < nx.offset) break;
                    cur.next = nx.next;
                    if (nx.writing_pos > newpos + seekThreshold(s)) {
                        newpos = nx.writing_pos;
                        reseek = true;
                    }
                    std.heap.c_allocator.destroy(nx);
                }
            }
        } else {
            const one = rb - wpos;
            const two = n - one;
            if (!put(q, wpos, data, one)) return false;
            if (usingTemp(s) and !fseekTo(s.temp_file, 0)) {
                resError(q, c.GST_RESOURCE_ERROR_SEEK, null, sysError(), "gst_queue2_create_write", 2262);
                return false;
            }
            if (!put(q, 0, data + one, two)) return false;
        }
        size -= n;
        const cur = s.current.?;
        if (usingRing(s)) {
            data += n;
            cur.writing_pos += n;
            cur.rb_writing_pos = newpos;
        } else cur.writing_pos = newpos;
        wpos = newpos;
        if (reseek) seekTo(q, newpos);
        updateCurLevel(s, s.current.?);
        if (s.use_buffering) updateBuffering(s);
        unlockQ(s);
        postBuffering(q);
        lockQ(s);
        signalAdd(s);
    }
    return true;
}

fn unexpectedEvent(ev: [*c]c.GstEvent) void {
    c.gst_mini_object_unref(@ptrCast(ev));
}

fn enqueue(q: *Self, item_in: [*c]c.GstMiniObject, kind: Kind) void {
    const s = q.st;
    var item = item_in;
    switch (kind) {
        .buffer => {
            const b: [*c]c.GstBuffer = @ptrCast(item);
            const size = c.gst_buffer_get_size(b);
            if (usingQueue(s)) {
                s.cur.buffers += 1;
                s.cur.bytes +%= @truncate(size);
            }
            s.bytes_in += size;
            applyBuffer(s, b, &s.sink_segment, size, true);
            updateInRates(s, false);
            if (!usingQueue(s)) _ = createWrite(q, b);
        },
        .list => {
            const l: ?*c.GstBufferList = @ptrCast(item);
            const size = c.gst_buffer_list_calculate_size(l);
            if (usingQueue(s)) {
                s.cur.buffers += c.gst_buffer_list_length(l);
                s.cur.bytes +%= @truncate(size);
            }
            s.bytes_in += size;
            applyList(s, l, &s.sink_segment, true);
            updateInRates(s, false);
            if (!usingQueue(s)) {
                var i: c.guint = 0;
                while (i < c.gst_buffer_list_length(l)) : (i += 1) {
                    if (!createWrite(q, c.gst_buffer_list_get(l, i))) break;
                }
            }
        },
        .event => {
            const ev: [*c]c.GstEvent = @ptrCast(item);
            switch (cm.eventType(ev)) {
                c.GST_EVENT_EOS => {
                    s.is_eos = true;
                    updateInRates(s, true);
                },
                c.GST_EVENT_SEGMENT => {
                    applySegment(s, ev, &s.sink_segment, true);
                    if (!usingQueue(s)) {
                        if (s.segment_received) return unexpectedEvent(ev);
                        s.segment_received = true;
                        if (s.starting_segment != null) c.gst_mini_object_unref(@ptrCast(s.starting_segment));
                        s.starting_segment = ev;
                        item = null;
                    }
                    s.unexpected = false;
                },
                c.GST_EVENT_GAP => applyGap(s, ev, &s.sink_segment, true),
                c.GST_EVENT_STREAM_START, c.GST_EVENT_CAPS => if (!usingQueue(s)) {
                    if (cm.eventType(ev) == c.GST_EVENT_STREAM_START) _ = c.gst_mini_object_replace(@ptrCast(&s.stream_start), @ptrCast(ev));
                    c.gst_mini_object_unref(@ptrCast(ev));
                    item = null;
                },
                else => if (!usingQueue(s)) return unexpectedEvent(ev),
            }
        },
        .query => if (!usingQueue(s)) c.g_assertion_message_expr(null, FILE, 2422, "gst_queue2_locked_enqueue", null),
        else => {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unexpected item %p added in queue %s (refcounting problem?)", item, cm.obj(q).name);
            item = null;
        },
    }
    if (item == null) return;
    if (s.use_buffering) updateBuffering(s);
    if (usingQueue(s)) {
        var it = Item{ .kind = kind, .item = item };
        c.gst_vec_deque_push_tail_struct(s.queue, &it);
    } else c.gst_mini_object_unref(item);
    signalAdd(s);
}

fn dequeue(q: *Self, kind: *Kind) [*c]c.GstMiniObject {
    const s = q.st;
    var item: [*c]c.GstMiniObject = null;
    if (!usingQueue(s)) {
        item = readItem(q);
    } else {
        const it: ?*Item = @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(s.queue)));
        if (it) |x| item = x.item;
    }
    if (item == null) return null;
    if (cm.isBuffer(item)) {
        const b: [*c]c.GstBuffer = @ptrCast(item);
        const size = c.gst_buffer_get_size(b);
        kind.* = .buffer;
        if (usingQueue(s)) {
            s.cur.buffers -%= 1;
            s.cur.bytes -%= @truncate(size);
        }
        s.bytes_out += size;
        applyBuffer(s, b, &s.src_segment, size, false);
        updateOutRates(s);
        if (s.use_buffering) updateBuffering(s);
    } else if (cm.isEvent(item)) {
        const ev: [*c]c.GstEvent = @ptrCast(item);
        kind.* = .event;
        switch (cm.eventType(ev)) {
            c.GST_EVENT_EOS => s.cur = .{},
            c.GST_EVENT_SEGMENT => applySegment(s, ev, &s.src_segment, false),
            c.GST_EVENT_GAP => applyGap(s, ev, &s.src_segment, false),
            else => {},
        }
    } else if (cm.isBufferList(item)) {
        const l: ?*c.GstBufferList = @ptrCast(item);
        const size = c.gst_buffer_list_calculate_size(l);
        kind.* = .list;
        if (usingQueue(s)) {
            s.cur.buffers -%= c.gst_buffer_list_length(l);
            s.cur.bytes -%= @truncate(size);
        }
        s.bytes_out += size;
        applyList(s, l, &s.src_segment, false);
        updateOutRates(s);
        if (s.use_buffering) updateBuffering(s);
    } else if (cm.isQuery(item)) {
        kind.* = .query;
    } else {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unexpected item %p dequeued from queue %s (refcounting problem?)", item, cm.obj(q).name);
        item = null;
        kind.* = .unknown;
    }
    signalDel(s);
    return item;
}

fn tagBitrate(ev: [*c]c.GstEvent) ?c.guint {
    var tags: ?*c.GstTagList = null;
    c.gst_event_parse_tag(ev, &tags);
    var rate: c.guint = 0;
    if (c.gst_tag_list_get_uint(tags, c.GST_TAG_BITRATE, &rate) != 0 or c.gst_tag_list_get_uint(tags, c.GST_TAG_NOMINAL_BITRATE, &rate) != 0) return rate;
    return null;
}

fn restartAfterEos(q: *Self) void {
    const s = q.st;
    s.is_eos = false;
    s.unexpected = false;
    s.seeking = false;
    s.src_tags_bitrate = 0;
    s.sink_tags_bitrate = 0;
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    const q = me(par);
    const s = q.st;
    var ok: c.gboolean = 1;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START => {
            if (cm.pad(q.srcpad).mode == c.GST_PAD_MODE_PUSH) {
                ok = c.gst_pad_push_event(q.srcpad, ev);
                lockQ(s);
                s.srcresult = c.GST_FLOW_FLUSHING;
                s.sinkresult = c.GST_FLOW_FLUSHING;
                signalAdd(s);
                signalDel(s);
                unlockQ(s);
                _ = c.gst_pad_pause_task(q.srcpad);
                lockQ(s);
            } else {
                lockQ(s);
                s.sinkresult = c.GST_FLOW_FLUSHING;
                signalDel(s);
                c.gst_mini_object_unref(@ptrCast(ev));
            }
            s.last_query = false;
            c.g_cond_signal(&s.query_handled);
            unlockQ(s);
        },
        c.GST_EVENT_FLUSH_STOP => {
            if (cm.pad(q.srcpad).mode == c.GST_PAD_MODE_PUSH) {
                ok = c.gst_pad_push_event(q.srcpad, ev);
                lockQ(s);
                lockedFlush(q, false, true);
                s.srcresult = c.GST_FLOW_OK;
                s.sinkresult = c.GST_FLOW_OK;
                restartAfterEos(q);
                resetRates(s);
                _ = c.gst_pad_start_task(q.srcpad, loop, q.srcpad, null);
                unlockQ(s);
            } else {
                lockQ(s);
                s.segment_received = false;
                restartAfterEos(q);
                s.sinkresult = c.GST_FLOW_OK;
                unlockQ(s);
                c.gst_mini_object_unref(@ptrCast(ev));
            }
            notify(q, PROP_BITRATE);
        },
        else => {
            if (cm.eventType(ev) == c.GST_EVENT_TAG and s.use_tags_bitrate) {
                if (tagBitrate(ev)) |rate| {
                    lockQ(s);
                    s.sink_tags_bitrate = rate;
                    unlockQ(s);
                    notify(q, PROP_BITRATE);
                }
            }
            if (!cm.eventSerialized(ev)) {
                ok = c.gst_pad_push_event(q.srcpad, ev);
            } else return serializedEvent(q, ev);
        },
    }
    return if (ok != 0) c.GST_FLOW_OK else c.GST_FLOW_ERROR;
}

fn serializedEvent(q: *Self, ev: [*c]c.GstEvent) c.GstFlowReturn {
    const s = q.st;
    const t = cm.eventType(ev);
    lockQ(s);
    const starts = t == c.GST_EVENT_STREAM_START or t == c.GST_EVENT_SEGMENT;
    if (s.sinkresult == c.GST_FLOW_EOS and starts) {
        s.sinkresult = c.GST_FLOW_OK;
    } else if (s.sinkresult != c.GST_FLOW_OK) {
        const r = s.sinkresult;
        unlockQ(s);
        c.gst_mini_object_unref(@ptrCast(ev));
        return r;
    }
    if (s.srcresult != c.GST_FLOW_OK and (!cm.eventSticky(ev) or t == c.GST_EVENT_EOS)) {
        if (cm.eventSticky(ev) and (s.srcresult == c.GST_FLOW_NOT_LINKED or s.srcresult < c.GST_FLOW_EOS)) cm.flowError(q, s.srcresult, FILE, "gst_queue2_handle_sink_event", 2702);
        const r = s.srcresult;
        unlockQ(s);
        c.gst_mini_object_unref(@ptrCast(ev));
        return r;
    }
    if (s.is_eos) {
        if (!starts) {
            unlockQ(s);
            c.gst_mini_object_unref(@ptrCast(ev));
            return c.GST_FLOW_EOS;
        }
        if (cm.pad(q.srcpad).mode == c.GST_PAD_MODE_PUSH) {
            s.srcresult = c.GST_FLOW_OK;
            restartAfterEos(q);
            resetRates(s);
            _ = c.gst_pad_start_task(q.srcpad, loop, q.srcpad, null);
        } else restartAfterEos(q);
    }
    enqueue(q, @ptrCast(ev), .event);
    unlockQ(s);
    postBuffering(q);
    notify(q, PROP_BITRATE);
    return c.GST_FLOW_OK;
}

fn sinkQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, qr: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const q = me(par);
    const s = q.st;
    if (!cm.querySerialized(qr)) return c.gst_pad_query_default(pad, par, qr);
    lockQ(s);
    if (s.sinkresult != c.GST_FLOW_OK) {
        unlockQ(s);
        return 0;
    }
    var res = false;
    if (usingQueue(s) and !s.use_buffering and @atomicLoad(c.gint, &s.may_block, .seq_cst) == 0) {
        enqueue(q, @ptrCast(qr), .query);
        while (s.sinkresult == c.GST_FLOW_OK and s.last_handled_query != qr) c.g_cond_wait(&s.query_handled, &s.qlock);
        s.last_handled_query = null;
        if (s.sinkresult != c.GST_FLOW_OK) {
            unlockQ(s);
            return 0;
        }
        res = s.last_query;
    }
    unlockQ(s);
    postBuffering(q);
    return @intFromBool(res);
}

fn isEmpty(s: *State) bool {
    if (s.is_eos) return false;
    if (!usingQueue(s)) {
        if (s.current) |r| return r.writing_pos <= r.max_reading_pos;
    }
    return c.gst_vec_deque_get_length(s.queue) == 0;
}

fn filledBy(cur: anytype, max: anytype) bool {
    return max > 0 and cur >= max;
}

fn isFilled(s: *State) bool {
    if (s.is_eos) return true;
    if (usingRing(s)) return s.max.bytes > 0 and s.cur.bytes >= (if (s.rb_max != 0) @min(@as(u64, s.max.bytes), s.rb_max) else s.max.bytes);
    if (usingTemp(s)) return false;
    if (s.cur.buffers == 0) return false;
    var r = filledBy(s.cur.buffers, s.max.buffers) or filledBy(s.cur.bytes, s.max.bytes) or filledBy(s.cur.time, s.max.time);
    if (s.use_rate_estimate) r = r or filledBy(s.cur.rate_time, s.max.rate_time);
    return r;
}

fn chainItem(q: *Self, item: [*c]c.GstMiniObject, kind: Kind) c.GstFlowReturn {
    const s = q.st;
    lockQ(s);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    if (s.sinkresult != c.GST_FLOW_OK) {
        ret = s.sinkresult;
    } else if (s.is_eos or s.unexpected) {
        ret = c.GST_FLOW_EOS;
    } else if (!s.seeking) {
        if (waitFreeSpace(s)) {
            enqueue(q, item, kind);
            unlockQ(s);
            postBuffering(q);
            return c.GST_FLOW_OK;
        }
        ret = s.sinkresult;
    }
    unlockQ(s);
    c.gst_mini_object_unref(item);
    return ret;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return chainItem(me(par), @ptrCast(b), .buffer);
}

fn chainList(_: ?*c.GstPad, par: [*c]c.GstObject, l: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    return chainItem(me(par), @ptrCast(@alignCast(l)), .list);
}

fn dequeueOnEos(q: *Self, kind: *Kind) [*c]c.GstMiniObject {
    const s = q.st;
    while (true) {
        const d = dequeue(q, kind);
        if (d == null) break;
        switch (kind.*) {
            .event => {
                const t = cm.eventType(d);
                if (t == c.GST_EVENT_EOS or t == c.GST_EVENT_SEGMENT or t == c.GST_EVENT_STREAM_START) return d;
                c.gst_mini_object_unref(d);
            },
            .query => {
                s.last_query = false;
                c.g_cond_signal(&s.query_handled);
            },
            else => c.gst_mini_object_unref(d),
        }
    }
    s.unexpected = true;
    return null;
}

fn queryBitrate(q: *Self) void {
    const s = q.st;
    const qr = c.gst_query_new_bitrate();
    var rate: c.guint = 0;
    if (c.gst_pad_peer_query(q.srcpad, qr) != 0) c.gst_query_parse_bitrate(qr, &rate);
    c.gst_mini_object_unref(@ptrCast(qr));
    lockQ(s);
    const changed = s.downstream_bitrate != rate;
    if (changed) {
        s.downstream_bitrate = rate;
        if (s.use_buffering) updateBuffering(s);
    }
    unlockQ(s);
    if (changed) {
        postBuffering(q);
        notify(q, PROP_BITRATE);
    }
}

fn pushOne(q: *Self) c.GstFlowReturn {
    const s = q.st;
    var kind: Kind = .unknown;
    var data = dequeue(q, &kind);
    if (data == null) return c.GST_FLOW_ERROR;
    while (true) {
        var result = s.srcresult;
        @atomicStore(c.gint, &s.may_block, @intFromBool(kind == .buffer or kind == .list), .seq_cst);
        unlockQ(s);
        postBuffering(q);
        if (c.gst_pad_check_reconfigure(q.srcpad) != 0) queryBitrate(q);
        switch (kind) {
            .buffer, .list => {
                result = if (kind == .buffer) c.gst_pad_push(q.srcpad, @ptrCast(data)) else c.gst_pad_push_list(q.srcpad, @ptrCast(data));
                @atomicStore(c.gint, &s.may_block, 0, .seq_cst);
                lockQ(s);
                if (s.srcresult != c.GST_FLOW_OK) return s.srcresult;
                if (result == c.GST_FLOW_EOS) {
                    data = dequeueOnEos(q, &kind);
                    if (data != null) continue;
                    result = c.GST_FLOW_OK;
                }
            },
            .event => {
                const ev: [*c]c.GstEvent = @ptrCast(data);
                const t = cm.eventType(ev);
                if (t == c.GST_EVENT_TAG and s.use_tags_bitrate) {
                    if (tagBitrate(ev)) |rate| {
                        lockQ(s);
                        s.src_tags_bitrate = rate;
                        unlockQ(s);
                        notify(q, PROP_BITRATE);
                    }
                }
                _ = c.gst_pad_push_event(q.srcpad, ev);
                if (t == c.GST_EVENT_EOS) result = c.GST_FLOW_EOS;
                lockQ(s);
                if (s.srcresult != c.GST_FLOW_OK) return s.srcresult;
            },
            .query => {
                const qr: [*c]c.GstQuery = @ptrCast(data);
                s.last_handled_query = qr;
                s.last_query = c.gst_pad_peer_query(q.srcpad, qr) != 0;
                c.g_cond_signal(&s.query_handled);
                lockQ(s);
                if (s.srcresult != c.GST_FLOW_OK) return s.srcresult;
                result = c.GST_FLOW_OK;
            },
            else => {},
        }
        return result;
    }
}

fn pauseLoop(q: *Self) void {
    const s = q.st;
    const eos = s.is_eos;
    const r = s.srcresult;
    _ = c.gst_pad_pause_task(q.srcpad);
    if (r != c.GST_FLOW_NOT_LINKED and r != c.GST_FLOW_EOS) {
        lockedFlush(q, false, false);
    } else {
        signalDel(s);
        s.last_query = false;
        c.g_cond_signal(&s.query_handled);
    }
    if (s.use_buffering) updateBuffering(s);
    unlockQ(s);
    postBuffering(q);
    if (eos and (r == c.GST_FLOW_NOT_LINKED or r < c.GST_FLOW_EOS)) {
        cm.flowError(q, r, FILE, "gst_queue2_loop", 3259);
        _ = c.gst_pad_push_event(q.srcpad, c.gst_event_new_eos());
    }
}

fn loop(data: c.gpointer) callconv(.c) void {
    const q = me(cm.padParent(@as(?*c.GstPad, @ptrCast(@alignCast(data)))));
    const s = q.st;
    lockQ(s);
    if (s.srcresult != c.GST_FLOW_OK) return pauseLoop(q);
    if (isEmpty(s)) {
        const started = s.out_started;
        if (started) c.g_timer_stop(s.out_timer);
        while (true) {
            if (!waitAdd(s)) return pauseLoop(q);
            if (!isEmpty(s)) break;
        }
        if (started) c.g_timer_continue(s.out_timer);
    }
    const r = pushOne(q);
    s.srcresult = r;
    s.sinkresult = r;
    if (r != c.GST_FLOW_OK) return pauseLoop(q);
    unlockQ(s);
    postBuffering(q);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const q = me(par);
    const s = q.st;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_START, c.GST_EVENT_FLUSH_STOP => {
            if (usingQueue(s)) return c.gst_pad_push_event(q.sinkpad, ev);
            lockQ(s);
            if (cm.eventType(ev) == c.GST_EVENT_FLUSH_START) {
                s.srcresult = c.GST_FLOW_FLUSHING;
                signalAdd(s);
            } else s.srcresult = c.GST_FLOW_OK;
            unlockQ(s);
            c.gst_mini_object_unref(@ptrCast(ev));
            return 1;
        },
        c.GST_EVENT_RECONFIGURE => {
            lockQ(s);
            if (s.srcresult == c.GST_FLOW_NOT_LINKED) {
                c.gst_pad_mark_reconfigure(pad);
                s.srcresult = c.GST_FLOW_OK;
                s.sinkresult = c.GST_FLOW_OK;
                if (cm.pad(pad).mode == c.GST_PAD_MODE_PUSH) _ = c.gst_pad_start_task(pad, loop, pad, null);
            }
            unlockQ(s);
        },
        else => {},
    }
    return c.gst_pad_push_event(q.sinkpad, ev);
}

fn bufferingQuery(q: *Self, qr: [*c]c.GstQuery) bool {
    const s = q.st;
    var buffering: c.gboolean = 0;
    const lv = bufferingLevel(s, &buffering) orelse LEVEL_MAX;
    const p = toPercent(s, lv);
    c.gst_query_set_buffering_percent(qr, buffering, p);
    const avg_in: c.gint = @intFromFloat(s.in_rate);
    c.gst_query_set_buffering_stats(qr, bufferingMode(s), avg_in, @intFromFloat(s.out_rate), bufferingLeft(s, p));
    if (usingQueue(s)) return true;
    const cur = s.current orelse return false;
    const wpos = cur.writing_pos;
    var dur: i64 = @bitCast(wpos);
    const known = s.is_eos or c.gst_pad_peer_query_duration(q.sinkpad, c.GST_FORMAT_BYTES, &dur) != 0;
    const total: i64 = if (known and avg_in > 0) @divTrunc((dur - @as(i64, @bitCast(wpos))) * 1000, avg_in) else -1;
    var fmt: c.GstFormat = 0;
    c.gst_query_parse_buffering_range(qr, &fmt, null, null, null);
    var start: i64 = -1;
    var stop: i64 = -1;
    switch (fmt) {
        c.GST_FORMAT_PERCENT => {
            if (!known) return false;
            start = 0;
            if (dur != -1) stop = @bitCast(c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, wpos, @bitCast(dur)));
        },
        c.GST_FORMAT_BYTES => {
            start = 0;
            stop = @bitCast(wpos);
        },
        else => {},
    }
    var r = s.ranges;
    while (r) |x| : (r = x.next) {
        var rs: i64 = -1;
        var re: i64 = -1;
        switch (fmt) {
            c.GST_FORMAT_PERCENT => if (dur == -1) {
                rs = 0;
                re = 0;
            } else {
                rs = @bitCast(c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, x.offset, @bitCast(dur)));
                re = @bitCast(c.gst_util_uint64_scale(c.GST_FORMAT_PERCENT_MAX, x.writing_pos, @bitCast(dur)));
            },
            c.GST_FORMAT_BYTES => {
                rs = @bitCast(x.offset);
                re = @bitCast(x.writing_pos);
            },
            else => {},
        }
        if (rs == re) continue;
        _ = c.gst_query_add_buffering_range(qr, rs, re);
    }
    c.gst_query_set_buffering_range(qr, fmt, start, stop, total);
    return true;
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, qr: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const q = me(par);
    const s = q.st;
    switch (cm.queryType(qr)) {
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(q.sinkpad, qr) == 0) return 0;
            var fmt: c.GstFormat = 0;
            var pos: i64 = 0;
            c.gst_query_parse_position(qr, &fmt, &pos);
            switch (fmt) {
                c.GST_FORMAT_BYTES => pos -= s.cur.bytes,
                c.GST_FORMAT_TIME => pos -%= @bitCast(s.cur.time),
                else => return 0,
            }
            if (pos < 0) pos = 0;
            c.gst_query_set_position(qr, fmt, pos);
        },
        c.GST_QUERY_DURATION => if (c.gst_pad_peer_query(q.sinkpad, qr) == 0) return 0,
        c.GST_QUERY_BUFFERING => if (!bufferingQuery(q, qr)) return 0,
        c.GST_QUERY_SCHEDULING => {
            const up = c.gst_query_new_scheduling();
            defer c.gst_mini_object_unref(@ptrCast(up));
            if (c.gst_pad_peer_query(q.sinkpad, up) == 0) return 0;
            var flags: c.GstSchedulingFlags = 0;
            c.gst_query_parse_scheduling(up, &flags, null, null, null);
            const pull = !usingQueue(s);
            if (pull) flags |= c.GST_SCHEDULING_FLAG_SEEKABLE;
            c.gst_query_set_scheduling(qr, flags, 0, -1, 0);
            if (pull) c.gst_query_add_scheduling_mode(qr, c.GST_PAD_MODE_PULL);
            c.gst_query_add_scheduling_mode(qr, c.GST_PAD_MODE_PUSH);
        },
        else => if (c.gst_pad_query_default(pad, par, qr) == 0) return 0,
    }
    return 1;
}

fn elementQuery(el: [*c]c.GstElement, qr: [*c]c.GstQuery) callconv(.c) c.gboolean {
    return srcQuery(me(el).srcpad, cm.obj(el), qr);
}

fn updateUpstream(q: *Self) void {
    var size: i64 = -1;
    if (c.gst_pad_peer_query_duration(q.sinkpad, c.GST_FORMAT_BYTES, &size) != 0) q.st.upstream_size = if (size >= 0) @intCast(size) else 0;
}

fn getRange(_: ?*c.GstPad, par: [*c]c.GstObject, off_in: u64, len_in: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const q = me(par);
    const s = q.st;
    var len: c.guint = if (len_in == std.math.maxInt(c.guint)) BLOCK else len_in;
    lockQ(s);
    if (s.srcresult != c.GST_FLOW_OK) {
        const r = s.srcresult;
        unlockQ(s);
        return r;
    }
    const off = if (off_in == NONE) s.current.?.reading_pos else off_in;
    if (off >= s.upstream_size) {
        updateUpstream(q);
        if (s.upstream_size > 0 and off >= s.upstream_size) {
            unlockQ(s);
            return c.GST_FLOW_EOS;
        }
    }
    if (off + len > s.upstream_size) {
        updateUpstream(q);
        if (s.upstream_size > 0 and off + len >= s.upstream_size) len = @truncate(s.upstream_size - off);
    }
    const r = createRead(q, off, len, out);
    unlockQ(s);
    postBuffering(q);
    return r;
}

fn sinkMode(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const q = me(par);
    const s = q.st;
    if (mode != c.GST_PAD_MODE_PUSH) return 0;
    lockQ(s);
    if (on != 0) {
        s.srcresult = c.GST_FLOW_OK;
        s.sinkresult = c.GST_FLOW_OK;
        s.is_eos = false;
        s.unexpected = false;
        resetRates(s);
        unlockQ(s);
        return 1;
    }
    s.srcresult = c.GST_FLOW_FLUSHING;
    s.sinkresult = c.GST_FLOW_FLUSHING;
    signalDel(s);
    unlockQ(s);
    cm.streamLock(pad);
    lockQ(s);
    lockedFlush(q, true, false);
    unlockQ(s);
    cm.streamUnlock(pad);
    return 1;
}

fn openStorage(q: *Self) bool {
    const s = q.st;
    if (usingTemp(s)) return openTemp(q);
    if (s.ring == null) s.ring = @ptrCast(c.g_malloc(s.rb_max));
    return s.ring != null;
}

fn srcMode(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const q = me(par);
    const s = q.st;
    switch (mode) {
        c.GST_PAD_MODE_PUSH => {
            lockQ(s);
            if (on != 0) {
                s.srcresult = c.GST_FLOW_OK;
                s.sinkresult = c.GST_FLOW_OK;
                s.is_eos = false;
                s.unexpected = false;
                const r = c.gst_pad_start_task(pad, loop, pad, null);
                unlockQ(s);
                return r;
            }
            s.srcresult = c.GST_FLOW_FLUSHING;
            s.sinkresult = c.GST_FLOW_FLUSHING;
            signalAdd(s);
            unlockQ(s);
            const r = c.gst_pad_stop_task(pad);
            lockQ(s);
            lockedFlush(q, false, false);
            unlockQ(s);
            return r;
        },
        c.GST_PAD_MODE_PULL => {
            lockQ(s);
            defer unlockQ(s);
            if (on == 0) {
                s.srcresult = c.GST_FLOW_FLUSHING;
                s.sinkresult = c.GST_FLOW_FLUSHING;
                signalAdd(s);
                return 1;
            }
            if (usingQueue(s)) {
                s.srcresult = c.GST_FLOW_FLUSHING;
                s.sinkresult = c.GST_FLOW_FLUSHING;
                return 0;
            }
            const ok = openStorage(q);
            initRanges(s);
            s.srcresult = c.GST_FLOW_OK;
            s.sinkresult = c.GST_FLOW_OK;
            s.is_eos = false;
            s.unexpected = false;
            s.upstream_size = 0;
            return @intFromBool(ok);
        },
        else => return 0,
    }
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const q = me(el);
    const s = q.st;
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        lockQ(s);
        var ok = true;
        if (!usingQueue(s)) {
            if (usingTemp(s)) {
                ok = openTemp(q);
            } else {
                if (s.ring) |r| c.g_free(r);
                s.ring = @ptrCast(c.g_malloc(s.rb_max));
                ok = s.ring != null;
            }
            initRanges(s);
        }
        s.segment_received = false;
        s.starting_segment = null;
        _ = c.gst_mini_object_replace(@ptrCast(&s.stream_start), null);
        unlockQ(s);
        c.gst_pad_mark_reconfigure(q.srcpad);
        if (!ok) return c.GST_STATE_CHANGE_FAILURE;
    }
    const r = parent.?.change_state.?(el, t);
    if (r == c.GST_STATE_CHANGE_FAILURE) return r;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        lockQ(s);
        if (!usingQueue(s)) {
            if (usingTemp(s)) {
                closeTemp(s);
            } else if (s.ring) |ring| {
                c.g_free(ring);
                s.ring = null;
            }
            cleanRanges(s);
        }
        if (s.starting_segment != null) {
            c.gst_mini_object_unref(@ptrCast(s.starting_segment));
            s.starting_segment = null;
        }
        _ = c.gst_mini_object_replace(@ptrCast(&s.stream_start), null);
        unlockQ(s);
    }
    return r;
}

fn capacityChanged(s: *State) void {
    signalDel(s);
    if (s.use_buffering) updateBuffering(s);
}

fn setTemplate(q: *Self, t: [*c]const u8) void {
    cm.lock(q);
    const st = element(q)[0].current_state;
    cm.unlock(q);
    if (st != c.GST_STATE_READY and st != c.GST_STATE_NULL) return;
    c.g_free(q.st.temp_template);
    q.st.temp_template = c.g_strdup(t);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const q = me(o);
    const s = q.st;
    lockQ(s);
    switch (id) {
        PROP_MAX_SIZE_BYTES => {
            s.max.bytes = c.g_value_get_uint(v);
            capacityChanged(s);
        },
        PROP_MAX_SIZE_BUFFERS => {
            s.max.buffers = c.g_value_get_uint(v);
            capacityChanged(s);
        },
        PROP_MAX_SIZE_TIME => {
            s.max.time = c.g_value_get_uint64(v);
            s.max.rate_time = s.max.time;
            capacityChanged(s);
        },
        PROP_USE_BUFFERING => {
            s.use_buffering = c.g_value_get_boolean(v) != 0;
            if (!s.use_buffering and s.is_buffering) {
                setPercent(s, 100);
                s.is_buffering = false;
            }
            if (s.use_buffering) {
                s.is_buffering = true;
                updateBuffering(s);
            }
        },
        PROP_USE_TAGS_BITRATE => s.use_tags_bitrate = c.g_value_get_boolean(v) != 0,
        PROP_USE_RATE_ESTIMATE => s.use_rate_estimate = c.g_value_get_boolean(v) != 0,
        PROP_LOW_PERCENT, PROP_HIGH_PERCENT, PROP_LOW_WATERMARK, PROP_HIGH_WATERMARK => {
            switch (id) {
                PROP_LOW_PERCENT => s.low_watermark = c.g_value_get_int(v) * PERCENT,
                PROP_HIGH_PERCENT => s.high_watermark = c.g_value_get_int(v) * PERCENT,
                PROP_LOW_WATERMARK => s.low_watermark = @intFromFloat(c.g_value_get_double(v) * LEVEL_MAX),
                else => s.high_watermark = @intFromFloat(c.g_value_get_double(v) * LEVEL_MAX),
            }
            if (s.is_buffering) updateBuffering(s);
        },
        PROP_TEMP_TEMPLATE => setTemplate(q, c.g_value_get_string(v)),
        PROP_TEMP_REMOVE => s.temp_remove = c.g_value_get_boolean(v) != 0,
        PROP_RING_BUFFER_MAX_SIZE => s.rb_max = c.g_value_get_uint64(v),
        PROP_USE_BITRATE_QUERY => s.use_bitrate_query = c.g_value_get_boolean(v) != 0,
        else => cm.warnInvalid(FILE, o, id, spec, 4003),
    }
    unlockQ(s);
    postBuffering(q);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const q = me(o);
    const s = q.st;
    lockQ(s);
    defer unlockQ(s);
    switch (id) {
        PROP_CUR_LEVEL_BYTES => c.g_value_set_uint(v, s.cur.bytes),
        PROP_CUR_LEVEL_BUFFERS => c.g_value_set_uint(v, s.cur.buffers),
        PROP_CUR_LEVEL_TIME => c.g_value_set_uint64(v, s.cur.time),
        PROP_MAX_SIZE_BYTES => c.g_value_set_uint(v, s.max.bytes),
        PROP_MAX_SIZE_BUFFERS => c.g_value_set_uint(v, s.max.buffers),
        PROP_MAX_SIZE_TIME => c.g_value_set_uint64(v, s.max.time),
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, @intFromBool(s.use_buffering)),
        PROP_USE_TAGS_BITRATE => c.g_value_set_boolean(v, @intFromBool(s.use_tags_bitrate)),
        PROP_USE_RATE_ESTIMATE => c.g_value_set_boolean(v, @intFromBool(s.use_rate_estimate)),
        PROP_LOW_PERCENT => c.g_value_set_int(v, @divTrunc(s.low_watermark, PERCENT)),
        PROP_HIGH_PERCENT => c.g_value_set_int(v, @divTrunc(s.high_watermark, PERCENT)),
        PROP_LOW_WATERMARK => c.g_value_set_double(v, @as(f64, @floatFromInt(s.low_watermark)) / LEVEL_MAX),
        PROP_HIGH_WATERMARK => c.g_value_set_double(v, @as(f64, @floatFromInt(s.high_watermark)) / LEVEL_MAX),
        PROP_TEMP_TEMPLATE => c.g_value_set_string(v, s.temp_template),
        PROP_TEMP_LOCATION => c.g_value_set_string(v, s.temp_location),
        PROP_TEMP_REMOVE => c.g_value_set_boolean(v, @intFromBool(s.temp_remove)),
        PROP_RING_BUFFER_MAX_SIZE => c.g_value_set_uint64(v, s.rb_max),
        PROP_AVG_IN_RATE => {
            var rate = s.in_rate;
            if (rate == 0.0 and s.bytes_in != 0 and s.last_update_in > 0.0) rate = @as(f64, @floatFromInt(s.bytes_in)) / s.last_update_in;
            c.g_value_set_int64(v, @intFromFloat(rate));
        },
        PROP_USE_BITRATE_QUERY => c.g_value_set_boolean(v, @intFromBool(s.use_bitrate_query)),
        PROP_BITRATE => {
            var rate: u64 = 0;
            if (s.use_tags_bitrate) rate = if (s.sink_tags_bitrate > 0) s.sink_tags_bitrate else s.src_tags_bitrate;
            if (rate == 0 and s.use_bitrate_query) rate = s.downstream_bitrate;
            c.g_value_set_uint64(v, rate);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 4104),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const q = me(o);
    const s = q.st;
    while (@as(?*Item, @ptrCast(@alignCast(c.gst_vec_deque_pop_head_struct(s.queue))))) |it| dropItem(it);
    c.gst_vec_deque_free(s.queue);
    c.g_mutex_clear(&s.qlock);
    c.g_mutex_clear(&s.post_lock);
    c.g_cond_clear(&s.item_add);
    c.g_cond_clear(&s.item_del);
    c.g_cond_clear(&s.query_handled);
    c.g_timer_destroy(s.in_timer);
    c.g_timer_destroy(s.out_timer);
    c.g_free(s.temp_template);
    c.g_free(s.temp_location);
    cleanRanges(s);
    if (s.ring) |r| c.g_free(r);
    std.heap.c_allocator.destroy(s);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const R = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const P = cm.RW | cm.MUTABLE_PLAYING;
    const U = std.math.maxInt(c.guint);
    const U64 = std.math.maxInt(u64);
    props[PROP_CUR_LEVEL_BYTES] = c.g_param_spec_uint("current-level-bytes", "Current level (kB)", "Current amount of data in the queue (bytes)", 0, U, 0, R);
    props[PROP_CUR_LEVEL_BUFFERS] = c.g_param_spec_uint("current-level-buffers", "Current level (buffers)", "Current number of buffers in the queue", 0, U, 0, R);
    props[PROP_CUR_LEVEL_TIME] = c.g_param_spec_uint64("current-level-time", "Current level (ns)", "Current amount of data in the queue (in ns)", 0, U64, 0, R);
    props[PROP_MAX_SIZE_BYTES] = c.g_param_spec_uint("max-size-bytes", "Max. size (kB)", "Max. amount of data in the queue (bytes, 0=disable)", 0, U, 2 * 1024 * 1024, P);
    props[PROP_MAX_SIZE_BUFFERS] = c.g_param_spec_uint("max-size-buffers", "Max. size (buffers)", "Max. number of buffers in the queue (0=disable)", 0, U, 100, P);
    props[PROP_MAX_SIZE_TIME] = c.g_param_spec_uint64("max-size-time", "Max. size (ns)", "Max. amount of data in the queue (in ns, 0=disable)", 0, U64, 2 * SEC, P);
    props[PROP_USE_BUFFERING] = c.g_param_spec_boolean("use-buffering", "Use buffering", "Emit GST_MESSAGE_BUFFERING based on low-/high-percent thresholds (0% = low-watermark, 100% = high-watermark)", 0, P);
    props[PROP_USE_TAGS_BITRATE] = c.g_param_spec_boolean("use-tags-bitrate", "Use bitrate from tags", "Use a bitrate from upstream tags to estimate buffer duration if not provided", 0, P);
    props[PROP_USE_RATE_ESTIMATE] = c.g_param_spec_boolean("use-rate-estimate", "Use Rate Estimate", "Estimate the bitrate of the stream to calculate time level", 1, cm.RW);
    props[PROP_LOW_PERCENT] = c.g_param_spec_int("low-percent", "Low percent", "Low threshold for buffering to start. Only used if use-buffering is True (Deprecated: use low-watermark instead)", 0, 100, 1, cm.RW);
    props[PROP_HIGH_PERCENT] = c.g_param_spec_int("high-percent", "High percent", "High threshold for buffering to finish. Only used if use-buffering is True (Deprecated: use high-watermark instead)", 0, 100, 99, cm.RW);
    props[PROP_LOW_WATERMARK] = c.g_param_spec_double("low-watermark", "Low watermark", "Low threshold for buffering to start. Only used if use-buffering is True", 0.0, 1.0, 0.01, cm.RW);
    props[PROP_HIGH_WATERMARK] = c.g_param_spec_double("high-watermark", "High watermark", "High threshold for buffering to finish. Only used if use-buffering is True", 0.0, 1.0, 0.99, cm.RW);
    props[PROP_TEMP_TEMPLATE] = c.g_param_spec_string("temp-template", "Temporary File Template", "File template to store temporary files in, should contain directory and XXXXXX. (NULL == disabled)", null, cm.RW);
    props[PROP_TEMP_LOCATION] = c.g_param_spec_string("temp-location", "Temporary File Location", "Location to store temporary files in (Only read this property, use temp-template to configure the name template)", null, R);
    props[PROP_USE_BITRATE_QUERY] = c.g_param_spec_boolean("use-bitrate-query", "Use bitrate from downstream query", "Use a bitrate from a downstream query to estimate buffer duration if not provided", 1, P);
    props[PROP_TEMP_REMOVE] = c.g_param_spec_boolean("temp-remove", "Remove the Temporary File", "Remove the temp-location after use", 1, cm.RW);
    props[PROP_RING_BUFFER_MAX_SIZE] = c.g_param_spec_uint64("ring-buffer-max-size", "Max. ring buffer size (bytes)", "Max. amount of data in the ring buffer (bytes, 0 = disabled)", 0, U64, 0, cm.RW);
    props[PROP_AVG_IN_RATE] = c.g_param_spec_int64("avg-in-rate", "Input data rate (bytes/s)", "Average input data rate (bytes/s)", 0, std.math.maxInt(i64), 0, R);
    props[PROP_BITRATE] = c.g_param_spec_uint64("bitrate", "Bitrate (bits/s)", "Conversion value between data size and time", 0, U64, 0, R);
    c.g_object_class_install_properties(oc, PROP_LAST, &props);
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Queue 2", "Generic", "Simple data queue", "Erik Walthinsen <omega@cse.ogi.edu>, Wim Taymans <wim.taymans@gmail.com>");
    ec.change_state = changeState;
    ec.query = elementQuery;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const q = me(inst);
    q.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(q.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(q.sinkpad, chainList, null, null);
    c.gst_pad_set_activatemode_function_full(q.sinkpad, sinkMode, null, null);
    c.gst_pad_set_event_full_function_full(q.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(q.sinkpad, sinkQuery, null, null);
    cm.setPadFlag(q.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(element(q), q.sinkpad);
    q.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_activatemode_function_full(q.srcpad, srcMode, null, null);
    c.gst_pad_set_getrange_function_full(q.srcpad, getRange, null, null);
    c.gst_pad_set_event_function_full(q.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(q.srcpad, srcQuery, null, null);
    cm.setPadFlag(q.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(element(q), q.srcpad);
    const s = std.heap.c_allocator.create(State) catch @panic("oom");
    s.* = .{};
    q.st = s;
    s.low_watermark = @intFromFloat(0.01 * @as(f64, LEVEL_MAX));
    s.high_watermark = @intFromFloat(0.99 * @as(f64, LEVEL_MAX));
    c.gst_segment_init(&s.sink_segment, c.GST_FORMAT_TIME);
    c.gst_segment_init(&s.src_segment, c.GST_FORMAT_TIME);
    s.in_timer = c.g_timer_new();
    s.out_timer = c.g_timer_new();
    c.g_mutex_init(&s.qlock);
    c.g_cond_init(&s.item_add);
    c.g_cond_init(&s.item_del);
    s.queue = c.gst_vec_deque_new_for_struct(@sizeOf(Item), 32);
    c.g_cond_init(&s.query_handled);
    c.g_mutex_init(&s.post_lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstQueue2", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("queue2", 0, "queue element");
            _ = c._gst_debug_category_new("queue2_dataflow", 0, "dataflow inside the queue element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "queue2", c.GST_RANK_NONE, getType()) != 0;
}
