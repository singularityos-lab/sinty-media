const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/videorate/gstvideorate.c";
const NONE: u64 = c.GST_CLOCK_TIME_NONE;
const SEC: u64 = c.GST_SECOND;
const CAPS = "video/x-raw(ANY);video/x-bayer(ANY);image/jpeg(ANY); image/x-jxsc(ANY), alignment=frame; image/png(ANY)";

const PROP_IN = 1;
const PROP_OUT = 2;
const PROP_DUP = 3;
const PROP_DROP = 4;
const PROP_SILENT = 5;
const PROP_NEW_PREF = 6;
const PROP_SKIP_TO_FIRST = 7;
const PROP_DROP_ONLY = 8;
const PROP_AVERAGE_PERIOD = 9;
const PROP_MAX_RATE = 10;
const PROP_RATE = 11;
const PROP_MAX_DUPLICATION_TIME = 12;
const PROP_MAX_CLOSING_SEGMENT_DUPLICATION_DURATION = 13;
const PROP_DROP_OUT_OF_SEGMENT = 14;

const Self = extern struct {
    parent: c.GstBaseTransform,
    from_n: c.gint,
    from_d: c.gint,
    to_n: c.gint,
    to_d: c.gint,
    next_ts: u64,
    next_end_ts: u64,
    prevbuf: [*c]c.GstBuffer,
    prevbuf_pushed: c.gboolean,
    prev_ts: u64,
    prev_end_ts: u64,
    out_count: u64,
    in_count: u64,
    base_out: u64,
    base_in: u64,
    discont: c.gboolean,
    last_ts: u64,
    average_period: u64,
    wanted_diff: i64,
    average: i64,
    force_variable_rate: c.gboolean,
    updating_caps: c.gboolean,
    max_duplication_time: u64,
    max_closing: u64,
    segment: c.GstSegment,
    in: u64,
    out: u64,
    dup: u64,
    drop: u64,
    silent: c.gboolean,
    new_pref: f64,
    skip_to_first: c.gboolean,
    drop_only: c.gboolean,
    drop_out_of_segment: c.gboolean,
    average_period_set: u64,
    max_rate: c.gint,
    rate: f64,
    pending_rate: f64,
    in_caps: [*c]c.GstCaps,
    prev_caps: [*c]c.GstCaps,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;
var pspec_drop: [*c]c.GParamSpec = null;
var pspec_dup: [*c]c.GParamSpec = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn valid(t: u64) bool {
    return t != NONE;
}

fn f(x: anytype) f64 {
    return @floatFromInt(x);
}

fn toI64(x: f64) i64 {
    if (std.math.isNan(x) or x >= 9223372036854775808.0 or x < -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(x);
}

fn toU64(x: f64) u64 {
    const top: f64 = 9223372036854775808.0;
    if (std.math.isNan(x) or x < top) return @bitCast(toI64(x));
    return @as(u64, @bitCast(toI64(x - top))) ^ 0x8000000000000000;
}

fn scale(v: u64, num: u64, den: u64) u64 {
    return c.gst_util_uint64_scale(v, num, den);
}

fn frameDur(den: c.gint, num: c.gint) u64 {
    return scale(1, @bitCast(@as(i64, den) * @as(i64, @intCast(SEC))), @bitCast(@as(i64, num)));
}

fn bf(b: [*c]c.GstBuffer) *c.GstBuffer {
    return cm.buf(b);
}

fn srcpad(s: *Self) ?*c.GstPad {
    return s.parent.srcpad;
}

fn sinkpad(s: *Self) ?*c.GstPad {
    return s.parent.sinkpad;
}

fn notifyDrop(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(s), pspec_drop);
}

fn notifyDup(s: *Self) void {
    c.g_object_notify_by_pspec(@ptrCast(s), pspec_dup);
}

fn fractionExtremes(v: [*c]const c.GValue, min_n: *c.gint, min_d: *c.gint, max_n: *c.gint, max_d: *c.gint) void {
    const t = v[0].g_type;
    if (t == c.gst_fraction_get_type()) {
        min_n.* = c.gst_value_get_fraction_numerator(v);
        max_n.* = min_n.*;
        min_d.* = c.gst_value_get_fraction_denominator(v);
        max_d.* = min_d.*;
    } else if (t == c.gst_fraction_range_get_type()) {
        const lo = c.gst_value_get_fraction_range_min(v);
        const hi = c.gst_value_get_fraction_range_max(v);
        min_n.* = c.gst_value_get_fraction_numerator(lo);
        min_d.* = c.gst_value_get_fraction_denominator(lo);
        max_n.* = c.gst_value_get_fraction_numerator(hi);
        max_d.* = c.gst_value_get_fraction_denominator(hi);
    } else if (t == c.gst_value_list_get_type()) {
        min_n.* = std.math.maxInt(c.gint);
        min_d.* = 1;
        max_n.* = 0;
        max_d.* = 1;
        var a: c.gint = std.math.maxInt(c.gint);
        var b: c.gint = 1;
        var x: c.gint = 0;
        var y: c.gint = 1;
        const n = c.gst_value_list_get_size(v);
        for (0..n) |i| {
            fractionExtremes(c.gst_value_list_get_value(v, @intCast(i)), &a, &b, &x, &y);
            if (c.gst_util_fraction_compare(a, b, min_n.*, min_d.*) < 0) {
                min_n.* = a;
                min_d.* = b;
            }
            if (c.gst_util_fraction_compare(x, y, max_n.*, max_d.*) > 0) {
                max_n.* = x;
                max_d.* = y;
            }
        }
    } else {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "Unknown type for framerate");
        min_n.* = 0;
        min_d.* = 1;
        max_n.* = std.math.maxInt(c.gint);
        max_d.* = 1;
    }
}

fn clampStructure(st: ?*c.GstStructure, maxrate: c.gint, min_n: *c.gint, min_d: *c.gint, max_n: *c.gint, max_d: *c.gint) bool {
    if (c.gst_structure_has_field(st, "framerate") == 0) return false;
    var clamp = std.mem.zeroes(c.GValue);
    var meet = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&clamp, c.gst_fraction_range_get_type());
    c.gst_value_set_fraction_range_full(&clamp, 0, 1, maxrate, 1);
    const v = c.gst_structure_get_value(st, "framerate");
    const ok = c.gst_value_intersect(&meet, v, &clamp) != 0;
    c.g_value_unset(&clamp);
    if (!ok) return false;
    fractionExtremes(&meet, min_n, min_d, max_n, max_d);
    var tn: c.gint = 0;
    var td: c.gint = 0;
    fractionExtremes(v, &tn, &td, max_n, max_d);
    if (c.gst_util_fraction_compare(max_n.*, max_d.*, maxrate, 1) > 0) {
        max_n.* = maxrate;
        max_d.* = 1;
    }
    c.gst_structure_take_value(st, "framerate", &meet);
    return true;
}

fn setRange(st: ?*c.GstStructure, a: c.gint, b: c.gint, x: c.gint, y: c.gint) void {
    c.gst_structure_set(st, "framerate", c.gst_fraction_range_get_type(), a, b, x, y, @as(?*anyopaque, null));
}

fn transformCaps(t: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(t);
    var ret = c.gst_caps_new_empty();
    const maxrate = @atomicLoad(c.gint, &s.max_rate, .seq_cst);
    const n = c.gst_caps_get_size(caps);
    for (0..n) |i| {
        const ix: c.guint = @intCast(i);
        const st = c.gst_caps_get_structure(caps, ix);
        var s1 = c.gst_structure_copy(st);
        if (s.updating_caps != 0 and dir == c.GST_PAD_SINK) {
            c.gst_structure_set(s1, "framerate", c.gst_fraction_get_type(), s.to_n, s.to_d, @as(?*anyopaque, null));
            ret = c.gst_caps_merge_structure(ret, s1);
            continue;
        }
        const s2 = c.gst_structure_copy(st);
        var s3: ?*c.GstStructure = null;
        if (s.drop_only != 0) {
            var min_n: c.gint = 0;
            var min_d: c.gint = 1;
            var max_n: c.gint = std.math.maxInt(c.gint);
            var max_d: c.gint = 1;
            if (!clampStructure(s1, maxrate, &min_n, &min_d, &max_n, &max_d)) {
                min_n = 0;
                min_d = 1;
                max_n = maxrate;
                max_d = 1;
                if (dir == c.GST_PAD_SRC and maxrate != std.math.maxInt(c.gint)) {
                    setRange(s1, min_n, min_d, maxrate, 1);
                } else {
                    c.gst_structure_free(s1);
                    s1 = null;
                }
            }
            if (dir == c.GST_PAD_SRC) {
                setRange(s2, min_n, min_d, std.math.maxInt(c.gint), 1);
                if (min_n != 0 or min_d != 1) {
                    s3 = c.gst_structure_copy(st);
                    c.gst_structure_set(s3, "framerate", c.gst_fraction_get_type(), @as(c.gint, 0), @as(c.gint, 1), @as(?*anyopaque, null));
                }
            } else if (max_n != 0 or max_d != 1) {
                setRange(s2, 0, 1, max_n, max_d);
            } else if (min_n == 0) {
                setRange(s2, min_n, 1, maxrate, 1);
            }
        } else if (dir == c.GST_PAD_SINK) {
            var min_n: c.gint = 0;
            var min_d: c.gint = 1;
            var max_n: c.gint = std.math.maxInt(c.gint);
            var max_d: c.gint = 1;
            if (!clampStructure(s1, maxrate, &min_n, &min_d, &max_n, &max_d)) {
                c.gst_structure_free(s1);
                s1 = null;
            }
            setRange(s2, 0, 1, maxrate, 1);
        } else {
            setRange(s2, 0, 1, std.math.maxInt(c.gint), 1);
        }
        const feats = c.gst_caps_get_features(caps, ix);
        if (s1 != null) ret = c.gst_caps_merge_structure_full(ret, s1, c.gst_caps_features_copy(feats));
        ret = c.gst_caps_merge_structure_full(ret, s2, c.gst_caps_features_copy(feats));
        if (s3 != null) ret = c.gst_caps_merge_structure_full(ret, s3, c.gst_caps_features_copy(feats));
    }
    if (filter != null) {
        const meet = c.gst_caps_intersect_full(filter, ret, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(ret);
        ret = meet;
    }
    return ret;
}

fn inputFrameDuration(s: *Self, b: [*c]c.GstBuffer) u64 {
    if (s.from_n != 0) return frameDur(s.from_d, s.from_n);
    if (b != null and bf(b).duration != 0) return bf(b).duration;
    if (s.prevbuf != null and bf(s.prevbuf).duration != 0) return bf(s.prevbuf).duration;
    if (s.to_n != 0) return frameDur(s.to_d, s.to_n);
    c.g_log(null, c.G_LOG_LEVEL_WARNING, "No duration available for input frame");
    return 0;
}

fn bestInputTs(s: *Self, b: [*c]c.GstBuffer, best: *u64) bool {
    if (s.segment.rate >= 0) {
        best.* = toU64(f(s.base_in) + f(s.next_ts -% s.base_out) * s.rate);
        return true;
    }
    if (!valid(s.next_ts)) return false;
    const in_dur = inputFrameDuration(s, b);
    const out_dur = if (s.to_n != 0) frameDur(s.to_d, s.to_n) else in_dur;
    best.* = toU64(f(s.base_in) - f(s.base_out -% (s.next_ts +% out_dur)) * s.rate - f(in_dur));
    return true;
}

fn fixateCaps(_: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var num: c.gint = 0;
    var den: c.gint = 0;
    if (c.gst_structure_get_fraction(c.gst_caps_get_structure(caps, 0), "framerate", &num, &den) == 0) return other;
    var o = c.gst_caps_truncate(other);
    o = c.gst_caps_make_writable(o);
    const st = c.gst_caps_get_structure(o, 0);
    _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", num, den);
    if (c.gst_structure_get_value(st, "pixel-aspect-ratio") != null) _ = c.gst_structure_fixate_field_nearest_fraction(st, "pixel-aspect-ratio", 1, 1);
    return c.gst_caps_fixate(o);
}

fn setCaps(t: [*c]c.GstBaseTransform, in_caps: [*c]c.GstCaps, out_caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(t);
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.gst_structure_get_fraction(c.gst_caps_get_structure(in_caps, 0), "framerate", &n, &d) == 0) return 0;
    s.from_n = n;
    s.from_d = d;
    if (c.gst_structure_get_fraction(c.gst_caps_get_structure(out_caps, 0), "framerate", &n, &d) == 0) return 0;
    if (s.to_n != 0 and s.out_count != 0) {
        _ = bestInputTs(s, null, &s.base_in);
        s.base_out +%= scale(s.out_count + @intFromBool(s.segment.rate < 0.0), @bitCast(@as(i64, s.to_d) * @as(i64, @intCast(SEC))), @bitCast(@as(i64, s.to_n)));
    }
    s.out_count = 0;
    s.to_n = n;
    s.to_d = d;
    s.wanted_diff = if (n != 0) @bitCast(c.gst_util_uint64_scale_int(SEC, d, n)) else 0;
    _ = c.gst_caps_replace(&s.in_caps, in_caps);
    return 1;
}

fn swapPrev(s: *Self, b: [*c]c.GstBuffer, time: u64, restore: [*c]c.GstCaps) void {
    const first = s.prevbuf == null;
    var count: c.gint = 0;
    if (restore != null) {
        _ = c.gst_pad_send_event(sinkpad(s), c.gst_event_new_caps(restore));
        c.gst_caps_unref(restore);
    }
    s.prevbuf_pushed = 0;
    _ = c.gst_buffer_replace(&s.prevbuf, b);
    if (b == null) {
        _ = c.gst_caps_replace(&s.prev_caps, null);
    } else if (s.prev_caps != s.in_caps) {
        _ = c.gst_caps_replace(&s.prev_caps, s.in_caps);
    }
    s.prev_ts = time;
    while (!first and b != null and pastBuffer(s)) {
        _ = flushPrev(s, s.prevbuf_pushed != 0, time, false);
        s.prevbuf_pushed = 1;
        count += 1;
    }
    if (count > 1) {
        s.dup +%= @intCast(count - 1);
        if (s.silent == 0) notifyDup(s);
    }
}

fn reset(s: *Self, on_flush: bool) void {
    s.in = 0;
    s.out = 0;
    s.base_in = 0;
    s.base_out = 0;
    s.out_count = 0;
    s.drop = 0;
    s.dup = 0;
    s.next_ts = NONE;
    s.next_end_ts = NONE;
    s.last_ts = NONE;
    s.discont = 1;
    s.average = 0;
    s.force_variable_rate = 0;
    if (!on_flush) {
        if (s.in_caps != null) c.gst_caps_unref(s.in_caps);
        s.in_caps = null;
    }
    swapPrev(s, null, 0, null);
    c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
}

fn pushBuffer(s: *Self, out: [*c]c.GstBuffer, duplicate: bool, next_in: u64, invalid_duration: bool) c.GstFlowReturn {
    const b = bf(out);
    b.offset = s.out;
    b.offset_end = s.out + 1;
    const mo: *c.GstMiniObject = @ptrCast(@alignCast(out));
    if (s.discont != 0) {
        mo.flags |= c.GST_BUFFER_FLAG_DISCONT;
        s.discont = 0;
    } else mo.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
    if (duplicate) mo.flags |= c.GST_BUFFER_FLAG_GAP else mo.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_GAP);
    const push_ts = s.next_ts;
    s.out +%= 1;
    s.out_count +%= 1;
    const span: u64 = @bitCast(@as(i64, s.to_d) * @as(i64, @intCast(SEC)));
    const num: u64 = @bitCast(@as(i64, s.to_n));
    if (s.segment.rate < 0.0) {
        s.next_end_ts = push_ts;
        if (s.to_n != 0) {
            const next: i64 = @bitCast(s.base_out -% scale(s.out_count + 1, span, num));
            s.next_ts = if (next < 0 or @as(u64, @bitCast(next)) < s.segment.start) NONE else @bitCast(next);
            b.duration = scale(s.out_count, span, num) -% scale(s.out_count - 1, span, num);
        } else if (next_in != NONE) {
            s.next_ts = next_in;
        }
    } else {
        s.next_end_ts = NONE;
        if (s.to_n != 0) {
            s.next_ts = s.base_out +% scale(s.out_count, span, num);
            b.duration = s.next_ts -% push_ts;
        } else if (!invalid_duration) {
            s.next_ts = b.pts +% b.duration;
        }
    }
    if (s.drop_only == 0) {
        b.pts = push_ts;
    } else {
        c.gst_buffer_unref(out);
        return c.GST_FLOW_OK;
    }
    if (s.drop_out_of_segment != 0 and c.gst_segment_clip(&s.segment, c.GST_FORMAT_TIME, b.pts, b.pts +% b.duration, null, null) == 0) {
        c.gst_buffer_unref(out);
        return c.GST_FLOW_OK;
    }
    return c.gst_pad_push(srcpad(s), out);
}

fn flushPrev(s: *Self, duplicate: bool, next_in: u64, invalid_duration: bool) c.GstFlowReturn {
    if (s.prevbuf == null) return c.GST_FLOW_OK;
    const out = c.gst_buffer_make_writable(c.gst_buffer_ref(s.prevbuf));
    return pushBuffer(s, out, duplicate, next_in, invalid_duration);
}

fn closeCheck(s: *Self, last_in: u64, first: bool) bool {
    const next = s.next_ts;
    const max = s.max_closing;
    const scaled = toU64(f(last_in) / s.rate);
    if (!valid(s.next_ts)) return false;
    if (s.segment.rate > 0.0) {
        if (!valid(s.segment.stop)) return first;
        if (next >= s.segment.stop) return false;
        if (valid(max)) {
            if (scaled > s.next_ts) return true;
            return s.next_ts - scaled < max;
        }
        return true;
    }
    if (!valid(s.segment.start)) return first;
    if (next < s.segment.start) return false;
    if (valid(max)) {
        if (scaled < s.next_ts) return true;
        return scaled - s.next_ts < max;
    }
    return true;
}

fn duplicateToClose(s: *Self) c.gint {
    var count: c.gint = 0;
    if (s.drop_only != 0 or s.prevbuf == null) return count;
    const last_in = s.prev_ts;
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    while (res == c.GST_FLOW_OK and closeCheck(s, last_in, count < 1)) {
        res = flushPrev(s, count > 0, NONE, false);
        count += 1;
    }
    return count;
}

fn rollbackCaps(s: *Self) [*c]c.GstCaps {
    var prev: [*c]c.GstCaps = null;
    if (s.prev_caps != null and s.prev_caps != s.in_caps) {
        if (s.in_caps != null) prev = c.gst_caps_ref(s.in_caps);
        if (c.gst_pad_send_event(sinkpad(s), c.gst_event_new_caps(s.prev_caps)) == 0) {
            swapPrev(s, null, NONE, null);
            s.last_ts = NONE;
            s.average = 0;
        }
        if (s.prev_caps != null) c.gst_caps_unref(s.prev_caps);
        s.prev_caps = null;
    }
    return prev;
}

fn convertPosition(old: *c.GstSegment, new: *c.GstSegment, pos0: u64) u64 {
    if (!cm.that(old.format == new.format, "convert_position", "old_segment->format == new_segment->format")) return NONE;
    if (pos0 == NONE) return NONE;
    var pos = pos0 +% old.base;
    if (pos < new.base) return NONE;
    pos -%= new.base;
    if (pos < new.start or (new.stop != NONE and pos > new.stop)) return NONE;
    return pos;
}

fn scaleDown(v: u64, rate: f64) u64 {
    return @bitCast(toI64(f(v) / rate));
}

fn sinkEvent(t: [*c]c.GstBaseTransform, ev0: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(t);
    var ev = ev0;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            c.gst_event_copy_segment(ev, &seg);
            if (seg.format != c.GST_FORMAT_TIME) return 0;
            const input = seg;
            seg.start = scaleDown(seg.start, s.rate);
            seg.position = scaleDown(seg.position, s.rate);
            if (valid(seg.stop)) seg.stop = scaleDown(seg.stop, s.rate);
            seg.time = scaleDown(seg.time, s.rate);
            if (c.gst_segment_is_equal(&seg, &s.segment) == 0) {
                const rolled = rollbackCaps(s);
                if (s.prevbuf != null) {
                    const count = duplicateToClose(s);
                    if (count > 1) {
                        s.dup +%= @intCast(count - 1);
                        if (s.silent == 0) notifyDup(s);
                    }
                    swapPrev(s, null, 0, null);
                }
                if (rolled != null) {
                    if (c.gst_pad_send_event(sinkpad(s), c.gst_event_new_caps(rolled)) == 0) {
                        if (@as(*c.GstObject, @ptrCast(@alignCast(t[0].srcpad))).flags & c.GST_PAD_FLAG_FLUSHING != 0) {
                            c.gst_caps_unref(rolled);
                            return 1;
                        }
                        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, c.g_strdup("Could not resend caps after closing segment"), null, FILE, "gst_video_rate_sink_event", 1202);
                        c.gst_caps_unref(rolled);
                        return 0;
                    }
                    c.gst_caps_unref(rolled);
                }
                s.next_ts = convertPosition(&s.segment, &seg, s.next_ts);
                s.last_ts = if (!valid(s.next_ts)) NONE else convertPosition(&s.segment, &seg, s.last_ts);
                if (valid(s.next_ts)) {
                    s.base_out = s.next_ts;
                    s.base_in = toU64(f(s.next_ts) * s.rate);
                } else if (seg.rate < 0) {
                    s.base_in = input.stop;
                    s.base_out = seg.stop;
                } else {
                    s.base_in = input.start;
                    s.base_out = seg.start;
                }
                s.out_count = 0;
                _ = c.gst_buffer_replace(&s.prevbuf, null);
            }
            c.gst_segment_copy_into(&seg, &s.segment);
            const seqnum = c.gst_event_get_seqnum(ev);
            c.gst_event_unref(ev);
            ev = c.gst_event_new_segment(&seg);
            c.gst_event_set_seqnum(ev, seqnum);
        },
        c.GST_EVENT_SEGMENT_DONE, c.GST_EVENT_EOS => {
            var count: c.gint = 0;
            var res: c.GstFlowReturn = c.GST_FLOW_OK;
            const rolled = rollbackCaps(s);
            if (valid(s.segment.stop)) {
                count = duplicateToClose(s);
            } else if (s.drop_only == 0 and s.prevbuf != null) {
                if (valid(bf(s.prevbuf).duration)) {
                    var dur = bf(s.prevbuf).duration;
                    if (valid(s.max_closing)) dur = @min(s.max_closing, dur);
                    const end = s.next_ts +% dur;
                    while (res == c.GST_FLOW_OK and ((s.segment.rate > 0.0 and valid(s.segment.stop) and valid(s.next_ts) and s.next_ts < end) or count < 1)) {
                        res = flushPrev(s, count > 0, NONE, false);
                        count += 1;
                    }
                } else {
                    res = flushPrev(s, false, NONE, true);
                    count = 1;
                }
            }
            if (rolled != null) {
                _ = c.gst_pad_send_event(sinkpad(s), c.gst_event_new_caps(rolled));
                c.gst_caps_unref(rolled);
            }
            if (count > 1) {
                s.dup +%= @intCast(count - 1);
                if (s.silent == 0) notifyDup(s);
            } else if (count == 0 and !valid(s.segment.stop)) {
                s.drop +%= 1;
                if (s.silent == 0) notifyDrop(s);
            }
        },
        c.GST_EVENT_FLUSH_STOP => reset(s, true),
        c.GST_EVENT_GAP => {
            c.gst_event_unref(ev);
            return 1;
        },
        else => {},
    }
    return parent.?.sink_event.?(t, ev);
}

fn srcEvent(t: [*c]c.GstBaseTransform, ev0: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(t);
    var ev = ev0;
    const pad = t[0].sinkpad;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEEK => {
            var srate: f64 = 0;
            var flags: c.GstSeekFlags = 0;
            var st: c.GstSeekType = 0;
            var et: c.GstSeekType = 0;
            var from: i64 = 0;
            var until: i64 = 0;
            const seqnum = c.gst_event_get_seqnum(ev);
            c.gst_event_parse_seek(ev, &srate, null, &flags, &st, &from, &et, &until);
            from = toI64(f(from) * s.rate);
            if (@as(u64, @bitCast(until)) != NONE) until = toI64(f(until) * s.rate);
            c.gst_event_unref(ev);
            ev = c.gst_event_new_seek(srate, c.GST_FORMAT_TIME, flags, st, from, et, until);
            c.gst_event_set_seqnum(ev, seqnum);
            return c.gst_pad_push_event(pad, ev);
        },
        c.GST_EVENT_QOS => {
            var kind: c.GstQOSType = 0;
            var prop: f64 = 0;
            var diff: i64 = 0;
            var ts: u64 = 0;
            c.gst_event_parse_qos(ev, &kind, &prop, &diff, &ts);
            if (valid(ts) and s.rate != 1.0) {
                cm.lock(s);
                diff = toI64(f(diff) * s.rate);
                const base_rt = c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, s.base_out);
                if (s.segment.rate < 0.0) {
                    const stop_rt = c.gst_segment_to_running_time(&s.segment, c.GST_FORMAT_TIME, s.segment.stop);
                    const span = stop_rt -% base_rt;
                    ts = toU64(f(span) - f(span -% ts) * s.rate);
                    if (diff < 0 and @as(u64, @bitCast(-%diff)) > ts) diff = 0;
                } else {
                    ts = toU64(f(base_rt) + f(ts -% base_rt) * s.rate);
                }
                cm.unlock(s);
                c.gst_event_unref(ev);
                ev = c.gst_event_new_qos(kind, prop, diff, ts);
            }
            return c.gst_pad_push_event(pad, ev);
        },
        else => return c.gst_pad_push_event(pad, ev),
    }
}

fn query(t: [*c]c.GstBaseTransform, dir: c.GstPadDirection, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(t);
    const other = if (dir == c.GST_PAD_SRC) t[0].sinkpad else t[0].srcpad;
    switch (cm.queryType(q)) {
        c.GST_QUERY_LATENCY => {
            cm.lock(s);
            const avg = s.average_period_set;
            const drop_only = s.drop_only;
            cm.unlock(s);
            if (avg == 0) {
                if (c.gst_pad_get_peer(other)) |peer| {
                    const res = c.gst_pad_query(peer, q);
                    if (res != 0) {
                        var live: c.gboolean = 0;
                        var min: u64 = 0;
                        var max: u64 = 0;
                        c.gst_query_parse_latency(q, &live, &min, &max);
                        const lat: u64 = if (drop_only == 0 and s.from_n != 0) scale(SEC, @bitCast(@as(i64, s.from_d)), @bitCast(@as(i64, s.from_n))) else 0;
                        min +%= lat;
                        if (max != NONE) max +%= lat;
                        c.gst_query_set_latency(q, live, min, max);
                    }
                    c.gst_object_unref(peer);
                    return res;
                }
            }
            return parent.?.query.?(t, dir, q);
        },
        c.GST_QUERY_DURATION => {
            const res = parent.?.query.?(t, dir, q);
            if (res == 0) return res;
            cm.lock(s);
            const rate = s.pending_rate;
            cm.unlock(s);
            if (rate == 1.0) return res;
            var fmt: c.GstFormat = 0;
            var dur: i64 = 0;
            c.gst_query_parse_duration(q, &fmt, &dur);
            if (fmt != c.GST_FORMAT_TIME) return res;
            if (@as(u64, @bitCast(dur)) != NONE) dur = toI64(f(dur) / rate);
            c.gst_query_set_duration(q, fmt, dur);
            return res;
        },
        c.GST_QUERY_POSITION => {
            cm.lock(s);
            const rate = s.rate;
            cm.unlock(s);
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(q, &fmt, null);
            if (fmt != c.GST_FORMAT_TIME) return 0;
            const v = c.gst_segment_to_stream_time(&s.segment, c.GST_FORMAT_TIME, toU64(f(s.last_ts) / rate));
            c.gst_query_set_position(q, fmt, @bitCast(v));
            return 1;
        },
        else => return parent.?.query.?(t, dir, q),
    }
}

fn proposeAllocation(t: [*c]c.GstBaseTransform, decide: [*c]c.GstQuery, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (!cm.that(decide == null, "gst_video_rate_propose_allocation", "decide_query == NULL")) return 0;
    const res = parent.?.propose_allocation.?(t, null, q);
    if (res == 0) return res;
    var i: c.guint = 0;
    var n = c.gst_query_get_n_allocation_pools(q);
    var down_min: c.guint = 0;
    while (i < n) {
        var pool: ?*c.GstBufferPool = null;
        var size: c.guint = 0;
        var min: c.guint = 0;
        var max: c.guint = 0;
        c.gst_query_parse_nth_allocation_pool(q, i, &pool, &size, &min, &max);
        if (max != 0 and min == max) {
            if (pool) |p| c.gst_object_unref(p);
            c.gst_query_remove_nth_allocation_pool(q, i);
            n -= 1;
            down_min = @max(min, down_min);
            continue;
        }
        c.gst_query_set_nth_allocation_pool(q, i, pool, size, min + 1, max);
        if (pool) |p| c.gst_object_unref(p);
        i += 1;
    }
    if (n == 0) {
        var caps: [*c]c.GstCaps = null;
        var info: c.GstVideoInfo = undefined;
        c.gst_query_parse_allocation(q, &caps, null);
        _ = c.gst_video_info_from_caps(&info, caps);
        c.gst_query_add_allocation_pool(q, null, @intCast(info.size), down_min + 1, 0);
    }
    return res;
}

fn maxAverage(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const ts = bf(b).pts;
    s.in +%= 1;
    if (valid(ts) and s.wanted_diff != 0) {
        if (valid(s.last_ts)) {
            const diff: i64 = @bitCast(if (s.segment.rate < 0) s.last_ts -% ts else ts -% s.last_ts);
            if (diff < s.wanted_diff and s.average < s.wanted_diff) {
                if (s.silent == 0) notifyDrop(s);
                return c.GST_BASE_TRANSFORM_FLOW_DROPPED;
            }
            if (s.average != 0) {
                const wanted: u64 = if (s.average_period > @as(u64, @bitCast(s.wanted_diff))) @bitCast(s.wanted_diff) else s.average_period *% 10;
                s.average = @bitCast(c.gst_util_uint64_scale_round(@bitCast(s.average), s.average_period -% wanted, s.average_period) +% c.gst_util_uint64_scale_round(@bitCast(diff), wanted, s.average_period));
            } else s.average = diff;
        }
        s.last_ts = ts;
    }
    s.out +%= 1;
    return c.GST_FLOW_OK;
}

fn checkVariableRate(s: *Self, b: [*c]c.GstBuffer) void {
    const caps = c.gst_pad_get_current_caps(srcpad(s));
    var n: c.gint = 0;
    var d: c.gint = 0;
    _ = c.gst_video_guess_framerate(bf(b).pts -% bf(s.prevbuf).pts, &n, &d);
    const tmp = c.gst_caps_copy(caps);
    c.gst_structure_set(c.gst_caps_get_structure(tmp, 0), "framerate", c.gst_fraction_get_type(), n, d, @as(?*anyopaque, null));
    c.gst_caps_unref(caps);
    const peer = c.gst_pad_get_peer(srcpad(s));
    const down = c.gst_pad_query_caps(peer, null);
    defer {
        c.gst_caps_unref(tmp);
        if (peer) |p| c.gst_object_unref(p);
    }
    if (peer != null and c.gst_caps_can_intersect(tmp, down) == 0) {
        s.force_variable_rate = 1;
        c.gst_caps_unref(down);
        return;
    }
    c.gst_caps_unref(down);
    s.to_n = n;
    s.to_d = d;
    s.updating_caps = 1;
    _ = c.gst_base_transform_update_src_caps(&s.parent, tmp);
    c.gst_base_transform_reconfigure_sink(&s.parent);
}

fn switchMode(s: *Self) bool {
    cm.lock(s);
    const avg = s.average_period_set;
    cm.unlock(s);
    if (avg == s.average_period) return false;
    if (!(avg == 0 or s.average_period == 0)) return false;
    var skip = false;
    s.average_period = avg;
    s.last_ts = NONE;
    if (avg != 0) {
        s.average = 0;
        swapPrev(s, null, 0, null);
    } else {
        s.next_ts = NONE;
        skip = true;
    }
    _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_latency(@ptrCast(s)));
    return skip;
}

fn maxDuplicate(s: *Self, b: [*c]c.GstBuffer, intime: u64, prevtime: u64) bool {
    if (s.max_duplication_time <= 0) return true;
    const diff: i64 = @bitCast(prevtime -% intime);
    if (@as(u64, @bitCast(if (diff < 0) -%diff else diff)) > s.max_duplication_time) {
        s.discont = 1;
        if (s.segment.rate < 0.0) {
            s.base_out = toU64(f(s.base_out) - f(prevtime -% intime) * s.rate);
            s.base_in = prevtime -% intime;
        } else {
            s.base_out = toU64(f(s.base_out) + f(intime -% prevtime) * s.rate);
            s.base_in +%= intime -% prevtime;
        }
        s.next_ts = toU64(f(intime) / s.rate);
        swapPrev(s, b, intime, null);
        return false;
    }
    return true;
}

fn applyPendingRate(s: *Self, b: [*c]c.GstBuffer) bool {
    cm.lock(s);
    defer cm.unlock(s);
    if (s.pending_rate == s.rate) return false;
    const span: u64 = @bitCast(@as(i64, s.to_d) * @as(i64, @intCast(SEC)));
    const num: u64 = @bitCast(@as(i64, s.to_n));
    if (s.segment.rate < 0) {
        const prev = s.base_in;
        if (!bestInputTs(s, b, &s.base_in)) s.base_in = prev;
        s.base_out -%= scale(s.out_count, span, num);
    } else {
        _ = bestInputTs(s, b, &s.base_in);
        s.base_out +%= scale(s.out_count, span, num);
    }
    s.rate = s.pending_rate;
    s.out_count = 0;
    return true;
}

fn computeNextTs(s: *Self, in_ts: u64, skip: bool) void {
    if (valid(s.next_ts)) return;
    if (s.skip_to_first != 0 or skip) {
        s.base_out = in_ts;
        s.base_in = in_ts;
        s.next_ts = in_ts;
        s.out_count = 0;
        return;
    }
    if (s.segment.rate >= 0.0) {
        s.next_ts = s.segment.start;
        return;
    }
    if (s.to_n != 0) {
        const dur = frameDur(s.to_d, s.to_n);
        s.next_ts = s.segment.stop;
        s.next_ts = if (s.next_ts > dur) @max(s.segment.start, s.next_ts - dur) else s.segment.start;
    } else s.next_ts = in_ts;
}

fn pastBuffer(s: *Self) bool {
    if (s.force_variable_rate != 0) return false;
    if (s.segment.rate < 0.0) {
        var next = s.next_ts;
        if (!valid(next)) return false;
        var end = next +% (if (s.to_n != 0) frameDur(s.to_d, s.to_n) else bf(s.prevbuf).duration);
        next = @intCast(@max(@as(i64, 0), toI64(f(s.base_out) - f(s.base_out -% next) * s.rate)));
        if (s.base_out > end) {
            end = @intCast(@max(@as(i64, 0), toI64(f(s.base_out) - f(s.base_out -% end) * s.rate)));
        } else end = s.base_out;
        return end >= s.prev_ts;
    }
    const next = toU64(f(s.base_out) + f(s.next_ts -% s.base_out) * s.rate);
    return next <= s.prev_ts;
}

fn transformIp(t: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(t);
    var res: c.GstFlowReturn = c.GST_BASE_TRANSFORM_FLOW_DROPPED;
    var restore: [*c]c.GstCaps = null;
    if (s.prev_caps != s.in_caps and s.new_pref < 1.0 and s.prevbuf != null) restore = rollbackCaps(s);
    body: {
        if (s.from_d == 0 or s.to_d == 0) {
            res = c.GST_FLOW_NOT_NEGOTIATED;
            break :body;
        }
        if (s.to_n == 0 and s.prevbuf != null and s.force_variable_rate == 0) {
            if (!valid(bf(b).pts) or !valid(bf(s.prevbuf).pts)) {
                cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup("videorate requires a non-variable framerate on the output caps or the two first consecutive buffers to have valid timestamps to guess the framerate."), FILE, "gst_video_rate_transform_ip", 1985);
                return c.GST_FLOW_ERROR;
            }
            checkVariableRate(s, b);
        }
        const skip = switchMode(s);
        if (s.average_period > 0) return maxAverage(s, b);
        var in_ts = bf(b).pts;
        const in_dur = bf(b).duration;
        if (s.segment.rate >= 0.0) computeNextTs(s, in_ts, skip);
        _ = applyPendingRate(s, b);
        if (!valid(in_ts)) {
            if (s.segment.rate < 0.0) break :body;
            in_ts = s.last_ts;
            if (!valid(in_ts)) break :body;
        }
        const last_ts = s.last_ts;
        s.last_ts = in_ts;
        if (valid(in_dur) and s.segment.rate > 0.0) s.last_ts +%= in_dur;
        if (s.prevbuf == null or s.drop_only != 0) {
            if (s.segment.rate < 0.0 and !valid(bf(b).duration)) {
                bf(b).duration = if (!valid(last_ts)) s.segment.stop -% in_ts else last_ts -% in_ts;
            }
            swapPrev(s, b, in_ts, null);
            s.in +%= 1;
            if (s.segment.rate < 0.0) computeNextTs(s, in_ts, skip);
            if (s.drop_only != 0) {
                if ((s.segment.rate > 0.0 and in_ts >= s.next_ts) or (s.segment.rate < 0.0 and in_ts <= s.next_ts)) {
                    res = pushBuffer(s, c.gst_buffer_ref(b), false, NONE, !valid(bf(b).duration));
                } else s.drop +%= 1;
                _ = c.gst_buffer_replace(&s.prevbuf, null);
            }
            break :body;
        }
        var count: c.gint = s.prevbuf_pushed;
        var diff1: i64 = 0;
        var diff2: i64 = 0;
        const prev_ts = s.prev_ts;
        s.in +%= 1;
        if ((s.segment.rate > 0.0 and in_ts < prev_ts) or (s.segment.rate < 0.0 and in_ts > prev_ts)) {
            s.drop +%= 1;
            if (s.silent == 0) notifyDrop(s);
            break :body;
        }
        if (!maxDuplicate(s, b, in_ts, prev_ts)) break :body;
        while (true) {
            var best: u64 = 0;
            if (applyPendingRate(s, b)) break :body;
            if (s.segment.rate < 0.0) {
                if (!valid(bf(b).duration)) bf(b).duration = if (prev_ts > in_ts) prev_ts - in_ts else 0;
            } else if (!valid(bf(s.prevbuf).duration)) {
                bf(s.prevbuf).duration = if (in_ts > prev_ts) in_ts - prev_ts else 0;
            }
            if (s.segment.rate < 0.0) {
                if (!bestInputTs(s, b, &best)) break;
                const best_end = best +% inputFrameDuration(s, b);
                const prev_end = prev_ts +% bf(s.prevbuf).duration;
                const in_end = in_ts +% bf(b).duration;
                diff1 = toI64(f(@as(i64, @bitCast(prev_end -% best_end))) * (1.0 - s.new_pref));
                diff2 = toI64(f(@as(i64, @bitCast(best_end -% in_end))) * s.new_pref);
            } else {
                if (!bestInputTs(s, b, &best)) c.g_log(null, c.G_LOG_LEVEL_ERROR, "Computing best input ts should always work on forward playback");
                diff1 = toI64(f(@as(i64, @bitCast(best -% prev_ts))) * s.new_pref);
                diff2 = toI64(f(@as(i64, @bitCast(in_ts -% best))) * (1.0 - s.new_pref));
            }
            if (diff1 <= diff2) {
                count += 1;
                const r = flushPrev(s, count > 1, in_ts, false);
                if (r != c.GST_FLOW_OK) {
                    res = r;
                    break :body;
                }
            }
            if (!(diff1 < diff2)) break;
        }
        if (count > 1) {
            s.dup +%= @intCast(count - 1);
            if (s.silent == 0) notifyDup(s);
        } else if (count == 0) {
            s.drop +%= 1;
            if (s.silent == 0) notifyDrop(s);
        }
        const r = restore;
        restore = null;
        swapPrev(s, b, in_ts, r);
    }
    if (restore != null) swapPrev(s, null, 0, restore);
    return res;
}

fn start(t: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    reset(me(t), false);
    return 1;
}

fn stop(t: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    reset(me(t), false);
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    var latency_changed = false;
    cm.lock(s);
    switch (id) {
        PROP_SILENT => s.silent = c.g_value_get_boolean(v),
        PROP_NEW_PREF => s.new_pref = c.g_value_get_double(v),
        PROP_SKIP_TO_FIRST => s.skip_to_first = c.g_value_get_boolean(v),
        PROP_DROP_ONLY => {
            const nv = c.g_value_get_boolean(v);
            latency_changed = nv != s.drop_only;
            s.drop_only = nv;
            cm.unlock(s);
            reconfigure(s, latency_changed);
            return;
        },
        PROP_AVERAGE_PERIOD => s.average_period_set = c.g_value_get_uint64(v),
        PROP_MAX_RATE => {
            @atomicStore(c.gint, &s.max_rate, c.g_value_get_int(v), .seq_cst);
            cm.unlock(s);
            reconfigure(s, false);
            return;
        },
        PROP_RATE => {
            s.pending_rate = c.g_value_get_double(v);
            cm.unlock(s);
            _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_duration_changed(@ptrCast(s)));
            return;
        },
        PROP_MAX_DUPLICATION_TIME => s.max_duplication_time = c.g_value_get_uint64(v),
        PROP_MAX_CLOSING_SEGMENT_DUPLICATION_DURATION => s.max_closing = c.g_value_get_uint64(v),
        PROP_DROP_OUT_OF_SEGMENT => s.drop_out_of_segment = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 2303),
    }
    cm.unlock(s);
}

fn reconfigure(s: *Self, latency_changed: bool) void {
    c.gst_base_transform_reconfigure_src(&s.parent);
    if (latency_changed) _ = c.gst_element_post_message(@ptrCast(s), c.gst_message_new_latency(@ptrCast(s)));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_IN => c.g_value_set_uint64(v, s.in),
        PROP_OUT => c.g_value_set_uint64(v, s.out),
        PROP_DUP => c.g_value_set_uint64(v, s.dup),
        PROP_DROP => c.g_value_set_uint64(v, s.drop),
        PROP_SILENT => c.g_value_set_boolean(v, s.silent),
        PROP_NEW_PREF => c.g_value_set_double(v, s.new_pref),
        PROP_SKIP_TO_FIRST => c.g_value_set_boolean(v, s.skip_to_first),
        PROP_DROP_ONLY => c.g_value_set_boolean(v, s.drop_only),
        PROP_AVERAGE_PERIOD => c.g_value_set_uint64(v, s.average_period_set),
        PROP_MAX_RATE => c.g_value_set_int(v, @atomicLoad(c.gint, &s.max_rate, .seq_cst)),
        PROP_RATE => c.g_value_set_double(v, s.pending_rate),
        PROP_MAX_DUPLICATION_TIME => c.g_value_set_uint64(v, s.max_duplication_time),
        PROP_MAX_CLOSING_SEGMENT_DUPLICATION_DURATION => c.g_value_set_uint64(v, s.max_closing),
        PROP_DROP_OUT_OF_SEGMENT => c.g_value_set_boolean(v, s.drop_out_of_segment),
        else => cm.warnInvalid(FILE, o, id, spec, 2372),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.set_caps = setCaps;
    tc.transform_caps = transformCaps;
    tc.transform_ip = transformIp;
    tc.sink_event = sinkEvent;
    tc.src_event = srcEvent;
    tc.start = start;
    tc.stop = stop;
    tc.fixate_caps = fixateCaps;
    tc.query = query;
    tc.propose_allocation = proposeAllocation;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const rw = cm.RW;
    c.g_object_class_install_property(oc, PROP_IN, c.g_param_spec_uint64("in", "In", "Number of input frames", 0, std.math.maxInt(u64), 0, ro));
    c.g_object_class_install_property(oc, PROP_OUT, c.g_param_spec_uint64("out", "Out", "Number of output frames", 0, std.math.maxInt(u64), 0, ro));
    pspec_dup = c.g_param_spec_uint64("duplicate", "Duplicate", "Number of duplicated frames", 0, std.math.maxInt(u64), 0, ro);
    c.g_object_class_install_property(oc, PROP_DUP, pspec_dup);
    pspec_drop = c.g_param_spec_uint64("drop", "Drop", "Number of dropped frames", 0, std.math.maxInt(u64), 0, ro);
    c.g_object_class_install_property(oc, PROP_DROP, pspec_drop);
    c.g_object_class_install_property(oc, PROP_SILENT, c.g_param_spec_boolean("silent", "silent", "Don't emit notify for dropped and duplicated frames", 1, rw));
    c.g_object_class_install_property(oc, PROP_NEW_PREF, c.g_param_spec_double("new-pref", "New Pref", "Value indicating how much to prefer new frames", 0.0, 1.0, 0.5, rw));
    c.g_object_class_install_property(oc, PROP_SKIP_TO_FIRST, c.g_param_spec_boolean("skip-to-first", "Skip to first buffer", "Don't produce buffers before the first one we receive", 0, rw));
    c.g_object_class_install_property(oc, PROP_DROP_ONLY, c.g_param_spec_boolean("drop-only", "Only Drop", "Only drop frames, no duplicates are produced", 0, rw));
    c.g_object_class_install_property(oc, PROP_AVERAGE_PERIOD, c.g_param_spec_uint64("average-period", "Period over which to average", "Period over which to average the framerate (in ns) (0 = disabled)", 0, std.math.maxInt(i64), 0, rw));
    c.g_object_class_install_property(oc, PROP_MAX_RATE, c.g_param_spec_int("max-rate", "maximum framerate", "Maximum framerate allowed to pass through (in frames per second, implies drop-only)", 1, std.math.maxInt(c.gint), std.math.maxInt(c.gint), rw | c.G_PARAM_CONSTRUCT));
    c.g_object_class_install_property(oc, PROP_RATE, c.g_param_spec_double("rate", "Rate", "Factor of speed for frame displaying", 0.0, std.math.floatMax(f64), 1.0, rw | cm.MUTABLE_READY));
    c.g_object_class_install_property(oc, PROP_MAX_DUPLICATION_TIME, c.g_param_spec_uint64("max-duplication-time", "Maximum time to duplicate a frame", "Do not duplicate frames if the gap exceeds this period (in ns) (0 = disabled)", 0, std.math.maxInt(u64), 0, rw));
    c.g_object_class_install_property(oc, PROP_MAX_CLOSING_SEGMENT_DUPLICATION_DURATION, c.g_param_spec_uint64("max-closing-segment-duplication-duration", "Maximum closing segment duplication duration", "Maximum duration of duplicated buffers to close current segment", 0, std.math.maxInt(u64), SEC, rw));
    c.g_object_class_install_property(oc, PROP_DROP_OUT_OF_SEGMENT, c.g_param_spec_boolean("drop-out-of-segment", "Drop out of segment buffers", "Drop out of segment buffers", 0, rw));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video rate adjuster", "Filter/Effect/Video", "Drops/duplicates/adjusts timestamps on video frames to make a perfect stream", "Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    _ = c._gst_debug_category_new("videorate", 0, "VideoRate stream fixer");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.prevbuf = null;
    s.in_caps = null;
    s.prev_caps = null;
    reset(s, false);
    s.silent = 1;
    s.new_pref = 0.5;
    s.drop_only = 0;
    s.drop_out_of_segment = 0;
    s.average_period = 0;
    s.average_period_set = 0;
    s.max_rate = std.math.maxInt(c.gint);
    s.rate = 1.0;
    s.pending_rate = 1.0;
    s.max_duplication_time = 0;
    s.max_closing = SEC;
    s.from_n = 0;
    s.from_d = 0;
    s.to_n = 0;
    s.to_d = 0;
    c.gst_base_transform_set_gap_aware(&s.parent, 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn mk() c.GType {
            return cm.register(c.gst_base_transform_get_type(), "GstVideoRate", Class, Self, classInit, init);
        }
    }.mk);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "videorate", c.GST_RANK_NONE, getType()) != 0;
}
