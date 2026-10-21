const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const NONE: u64 = std.math.maxInt(u64);

const Align = extern struct {
    rate: c.gint,
    alignment_threshold: u64,
    discont_wait: u64,
    next_offset: u64,
    timestamp_at_discont: u64,
    samples_since_discont: u64,
    discont_time: u64,
};

const A = c.GstAudioStreamAlign;

fn of(a: anytype) *Align {
    return @ptrCast(@alignCast(@constCast(a)));
}

var type_once: gtype.Once = .{};

fn copyBoxed(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_audio_stream_align_copy(@ptrCast(p));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_audio_stream_align_free(@ptrCast(p));
}

pub export fn gst_audio_stream_align_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAudioStreamAlign", copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_audio_stream_align_new(rate: c.gint, threshold: c.GstClockTime, wait: c.GstClockTime) ?*A {
    const fname = "gst_audio_stream_align_new";
    if (!check.that(rate != 0, fname, "rate != 0")) return null;
    if (!check.that(threshold != NONE, fname, "GST_CLOCK_TIME_IS_VALID (alignment_threshold)")) return null;
    if (!check.that(wait != NONE, fname, "GST_CLOCK_TIME_IS_VALID (discont_wait)")) return null;
    const a: *Align = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Align))));
    a.rate = rate;
    a.alignment_threshold = threshold;
    a.discont_wait = wait;
    a.timestamp_at_discont = NONE;
    a.samples_since_discont = 0;
    gst_audio_stream_align_mark_discont(@ptrCast(a));
    return @ptrCast(a);
}

pub export fn gst_audio_stream_align_copy(a: ?*const A) ?*A {
    if (!check.that(a != null, "gst_audio_stream_align_copy", "align != NULL")) return null;
    const n: *Align = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Align))));
    n.* = of(a).*;
    return @ptrCast(n);
}

pub export fn gst_audio_stream_align_free(a: ?*A) void {
    if (!check.that(a != null, "gst_audio_stream_align_free", "align != NULL")) return;
    c.g_free(a);
}

pub export fn gst_audio_stream_align_set_rate(a: ?*A, rate: c.gint) void {
    if (!check.that(a != null, "gst_audio_stream_align_set_rate", "align != NULL")) return;
    if (!check.that(rate != 0, "gst_audio_stream_align_set_rate", "rate != 0")) return;
    if (of(a).rate == rate) return;
    of(a).rate = rate;
    gst_audio_stream_align_mark_discont(a);
}

pub export fn gst_audio_stream_align_get_rate(a: ?*const A) c.gint {
    if (!check.that(a != null, "gst_audio_stream_align_get_rate", "align != NULL")) return 0;
    return of(a).rate;
}

pub export fn gst_audio_stream_align_set_alignment_threshold(a: ?*A, t: c.GstClockTime) void {
    if (!check.that(a != null, "gst_audio_stream_align_set_alignment_threshold", "align != NULL")) return;
    if (!check.that(t != NONE, "gst_audio_stream_align_set_alignment_threshold", "GST_CLOCK_TIME_IS_VALID (alignment_threshold)")) return;
    of(a).alignment_threshold = t;
}

pub export fn gst_audio_stream_align_get_alignment_threshold(a: ?*const A) c.GstClockTime {
    if (!check.that(a != null, "gst_audio_stream_align_get_alignment_threshold", "align != NULL")) return 0;
    return of(a).alignment_threshold;
}

pub export fn gst_audio_stream_align_set_discont_wait(a: ?*A, w: c.GstClockTime) void {
    if (!check.that(a != null, "gst_audio_stream_align_set_discont_wait", "align != NULL")) return;
    if (!check.that(w != NONE, "gst_audio_stream_align_set_discont_wait", "GST_CLOCK_TIME_IS_VALID (discont_wait)")) return;
    of(a).discont_wait = w;
}

pub export fn gst_audio_stream_align_get_discont_wait(a: ?*const A) c.GstClockTime {
    if (!check.that(a != null, "gst_audio_stream_align_get_discont_wait", "align != NULL")) return 0;
    return of(a).discont_wait;
}

pub export fn gst_audio_stream_align_mark_discont(a: ?*A) void {
    if (!check.that(a != null, "gst_audio_stream_align_mark_discont", "align != NULL")) return;
    of(a).next_offset = NONE;
    of(a).discont_time = NONE;
}

pub export fn gst_audio_stream_align_get_timestamp_at_discont(a: ?*const A) c.GstClockTime {
    if (!check.that(a != null, "gst_audio_stream_align_get_timestamp_at_discont", "align != NULL")) return NONE;
    return of(a).timestamp_at_discont;
}

pub export fn gst_audio_stream_align_get_samples_since_discont(a: ?*const A) c_ulong {
    if (!check.that(a != null, "gst_audio_stream_align_get_samples_since_discont", "align != NULL")) return 0;
    return of(a).samples_since_discont;
}

fn absdiff(x: u64, y: u64) u64 {
    return if (x > y) x - y else y - x;
}

pub export fn gst_audio_stream_align_process(ap: ?*A, discont_in: c.gboolean, timestamp_in: c.GstClockTime, n_samples: c.guint, out_ts: [*c]c.GstClockTime, out_dur: [*c]c.GstClockTime, out_pos: [*c]c_ulong) c.gboolean {
    if (!check.that(ap != null, "gst_audio_stream_align_process", "align != NULL")) return 0;
    const a = of(ap);
    const arate: u64 = @abs(a.rate);
    var timestamp = timestamp_in;
    const start_time = timestamp;
    var start_offset = c.gst_util_uint64_scale(start_time, arate, c.GST_SECOND);
    const end_offset = start_offset +% n_samples;
    const end_time = c.gst_util_uint64_scale_int(end_offset, c.GST_SECOND, @intCast(arate));
    var duration = end_time -% start_time;
    var discont = discont_in != 0;
    if (a.next_offset == NONE or discont) {
        discont = true;
    } else {
        const diff = if (a.rate > 0) absdiff(start_offset, a.next_offset) else absdiff(end_offset, a.next_offset);
        const expected = c.gst_util_uint64_scale(a.next_offset, c.GST_SECOND, arate);
        const max_diff = @max(1, c.gst_util_uint64_scale_int(a.alignment_threshold, @intCast(arate), c.GST_SECOND));
        if (diff >= max_diff) {
            if (a.discont_wait > 0) {
                if (a.discont_time == NONE) {
                    if (a.rate > 0 and absdiff(expected, start_time) >= a.discont_wait) {
                        discont = true;
                    } else if (a.rate < 0 and absdiff(expected, end_time) >= a.discont_wait) {
                        discont = true;
                    } else a.discont_time = expected;
                } else if ((a.rate > 0 and absdiff(start_time, a.discont_time) >= a.discont_wait) or (a.rate < 0 and absdiff(end_time, a.discont_time) >= a.discont_wait)) {
                    discont = true;
                    a.discont_time = NONE;
                }
            } else discont = true;
        } else if (a.discont_time != NONE) a.discont_time = NONE;
    }
    if (discont) {
        a.next_offset = if (a.rate > 0) end_offset else start_offset;
        a.timestamp_at_discont = start_time;
        a.samples_since_discont = 0;
        a.discont_time = NONE;
    } else if (a.rate > 0) {
        timestamp = c.gst_util_uint64_scale(a.next_offset, c.GST_SECOND, arate);
        start_offset = a.next_offset;
        a.next_offset +%= n_samples;
        duration = c.gst_util_uint64_scale(a.next_offset, c.GST_SECOND, arate) -% timestamp;
    } else {
        const old = a.next_offset;
        a.next_offset = if (a.next_offset > n_samples) a.next_offset - n_samples else 0;
        start_offset = a.next_offset;
        timestamp = c.gst_util_uint64_scale(a.next_offset, c.GST_SECOND, arate);
        duration = c.gst_util_uint64_scale(old, c.GST_SECOND, arate) -% timestamp;
    }
    a.samples_since_discont +%= n_samples;
    if (out_ts != null) out_ts.* = timestamp;
    if (out_dur != null) out_dur.* = duration;
    if (out_pos != null) out_pos.* = start_offset;
    return @intFromBool(discont);
}
