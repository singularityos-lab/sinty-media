const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const value = @import("value.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Seg = c.GstSegment;
const NONE: u64 = std.math.maxInt(u64);

var type_once: gtype.Once = .{};

fn toInt(x: f64) u64 {
    if (!(x > 0)) return 0;
    if (x >= 18446744073709551615.0) return NONE;
    return @intFromFloat(x);
}

fn times(x: u64, r: f64) u64 {
    return toInt(@as(f64, @floatFromInt(x)) * r);
}

fn divided(x: u64, r: f64) u64 {
    return toInt(@as(f64, @floatFromInt(x)) / r);
}

fn ceilTimes(x: u64, r: f64) u64 {
    return toInt(@ceil(@as(f64, @floatFromInt(x)) * r));
}

pub export fn gst_segment_copy(s: [*c]const Seg) [*c]Seg {
    if (s == null) return null;
    return @ptrCast(@alignCast(c.g_memdup2(s, @sizeOf(Seg))));
}

pub export fn gst_segment_copy_into(src: [*c]const Seg, dest: [*c]Seg) void {
    dest.* = src.*;
}

pub export fn gst_segment_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstSegment", @ptrCast(&gst_segment_copy), @ptrCast(&gst_segment_free));
        }
    }.f);
}

pub export fn gst_segment_new() [*c]Seg {
    const s: [*c]Seg = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Seg))));
    gst_segment_init(s, c.GST_FORMAT_UNDEFINED);
    return s;
}

pub export fn gst_segment_free(s: [*c]Seg) void {
    c.g_free(s);
}

pub export fn gst_segment_init(s: [*c]Seg, format: c.GstFormat) void {
    if (!check.that(s != null, "gst_segment_init", "segment != NULL")) return;
    s.* = .{ .flags = c.GST_SEGMENT_FLAG_NONE, .rate = 1.0, .applied_rate = 1.0, .format = format, .base = 0, .offset = 0, .start = 0, .stop = NONE, .time = 0, .position = 0, .duration = NONE };
}

fn signedMax0(x: u64) u64 {
    return if (@as(i64, @bitCast(x)) < 0) 0 else x;
}

pub export fn gst_segment_do_seek(s: [*c]Seg, rate: c.gdouble, format: c.GstFormat, flags: c.GstSeekFlags, start_type: c.GstSeekType, start_in: c.guint64, stop_type: c.GstSeekType, stop_in: c.guint64, update: [*c]c.gboolean) c.gboolean {
    const f = "gst_segment_do_seek";
    if (!check.that(rate != 0.0, f, "rate != 0.0")) return 0;
    if (!check.that(s != null, f, "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, f, "segment->format == format")) return 0;
    if (flags & c.GST_SEEK_FLAG_INSTANT_RATE_CHANGE != 0) return 0;
    var start = start_in;
    var stop = stop_in;
    var update_start = true;
    var update_stop = true;
    var position = s[0].position;
    switch (start_type) {
        c.GST_SEEK_TYPE_NONE => {
            start = s[0].start;
            update_start = false;
        },
        c.GST_SEEK_TYPE_SET => if (start == NONE) {
            start = 0;
        },
        c.GST_SEEK_TYPE_END => if (s[0].duration != NONE) {
            start = s[0].duration +% start;
        } else {
            start = s[0].start;
            update_start = false;
        },
        else => {},
    }
    start = if (s[0].duration != NONE) @min(start, s[0].duration) else signedMax0(start);
    switch (stop_type) {
        c.GST_SEEK_TYPE_NONE => {
            stop = s[0].stop;
            update_stop = false;
        },
        c.GST_SEEK_TYPE_END => if (s[0].duration != NONE) {
            stop = s[0].duration +% stop;
        } else {
            stop = s[0].stop;
            update_stop = false;
        },
        else => {},
    }
    if (stop != NONE) {
        if (s[0].duration != NONE) {
            const st: i64 = @bitCast(stop);
            stop = @bitCast(std.math.clamp(st, 0, @as(i64, @bitCast(s[0].duration))));
        } else stop = signedMax0(stop);
        if (start > stop) {
            check.fail(f, "start <= stop");
            return 0;
        }
    }
    var base: u64 = 0;
    if (flags & c.GST_SEEK_FLAG_FLUSH == 0) {
        position = @max(@min(position, s[0].stop), s[0].start);
        base = gst_segment_to_running_time(s, format, position);
    }
    if (update_start and rate > 0.0) position = start;
    if (update_stop and rate < 0.0) {
        position = if (stop != NONE) stop else if (s[0].duration != NONE) s[0].duration else 0;
    }
    if (update != null) update.* = @intFromBool(position != s[0].position);
    var sf: c.GstSegmentFlags = c.GST_SEGMENT_FLAG_NONE;
    if (flags & c.GST_SEEK_FLAG_FLUSH != 0) sf |= c.GST_SEGMENT_FLAG_RESET;
    if (flags & c.GST_SEEK_FLAG_TRICKMODE != 0) sf |= c.GST_SEGMENT_FLAG_TRICKMODE;
    if (flags & c.GST_SEEK_FLAG_SEGMENT != 0) sf |= c.GST_SEGMENT_FLAG_SEGMENT;
    if (flags & c.GST_SEEK_FLAG_TRICKMODE_KEY_UNITS != 0) sf |= c.GST_SEGMENT_FLAG_TRICKMODE_KEY_UNITS;
    if (flags & c.GST_SEEK_FLAG_TRICKMODE_NO_AUDIO != 0) sf |= c.GST_SEGMENT_FLAG_TRICKMODE_NO_AUDIO;
    if (flags & c.GST_SEEK_FLAG_TRICKMODE_FORWARD_PREDICTED != 0) sf |= c.GST_SEGMENT_FLAG_TRICKMODE_FORWARD_PREDICTED;
    s[0].flags = sf;
    s[0].rate = rate;
    s[0].applied_rate = 1.0;
    s[0].base = base;
    s[0].offset = if (rate > 0.0) position -% start else if (stop != NONE) stop -% position else if (s[0].duration != NONE) s[0].duration -% position else 0;
    s[0].start = start;
    s[0].stop = stop;
    s[0].time = start;
    s[0].position = position;
    return 1;
}

pub export fn gst_segment_to_stream_time_full(s: [*c]const Seg, format: c.GstFormat, position: c.guint64, out: [*c]c.guint64) c.gint {
    if (position == NONE) {
        out.* = NONE;
        return 0;
    }
    if (!check.that(s != null, "gst_segment_to_stream_time_full", "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, "gst_segment_to_stream_time_full", "segment->format == format")) return 0;
    const start = s[0].start;
    const stop = s[0].stop;
    const time = s[0].time;
    if (time == NONE) return 0;
    const r = @abs(s[0].applied_rate);
    var v: u64 = undefined;
    if (s[0].applied_rate > 0.0) {
        if (position > start) {
            v = position - start;
            if (r != 1.0) v = times(v, r);
            out.* = v +% time;
            return 1;
        }
        v = start - position;
        if (r != 1.0) v = times(v, r);
        if (v > time) {
            out.* = v - time;
            return -1;
        }
        out.* = time - v;
        return 1;
    }
    if (stop == NONE) return 0;
    if (position > stop) {
        v = position - stop;
        if (r != 1.0) v = times(v, r);
        if (v > time) {
            out.* = v - time;
            return -1;
        }
        out.* = time - v;
        return 1;
    }
    v = stop - position;
    if (r != 1.0) v = times(v, r);
    out.* = v +% time;
    return 1;
}

fn outside(s: [*c]const Seg, p: u64) bool {
    return p < s[0].start or (s[0].stop != NONE and p > s[0].stop);
}

pub export fn gst_segment_to_stream_time(s: [*c]const Seg, format: c.GstFormat, position: c.guint64) c.guint64 {
    if (!check.that(s != null, "gst_segment_to_stream_time", "segment != NULL")) return NONE;
    if (!check.that(s[0].format == format, "gst_segment_to_stream_time", "segment->format == format")) return NONE;
    if (outside(s, position)) return NONE;
    var r: u64 = 0;
    return if (gst_segment_to_stream_time_full(s, format, position, &r) == 1) r else NONE;
}

pub export fn gst_segment_position_from_stream_time_full(s: [*c]const Seg, format: c.GstFormat, stream_time: c.guint64, out: [*c]c.guint64) c.gint {
    if (stream_time == NONE) {
        out.* = NONE;
        return 0;
    }
    if (!check.that(s != null, "gst_segment_position_from_stream_time_full", "segment != NULL")) return -1;
    if (!check.that(s[0].format == format, "gst_segment_position_from_stream_time_full", "segment->format == format")) return -1;
    const start = s[0].start;
    const time = s[0].time;
    if (time == NONE) return 0;
    const r = @abs(s[0].applied_rate);
    var res: c.gint = undefined;
    var p: u64 = undefined;
    if (s[0].applied_rate > 0.0) {
        if (stream_time > time) {
            res = 1;
            p = stream_time - time;
        } else {
            res = -1;
            p = time - stream_time;
        }
        if (r != 1.0) p = divided(p, r);
        if (res == -1) {
            if (p > start) p -= start else {
                p = start - p;
                res = 1;
            }
        } else p +%= start;
    } else {
        const stop = s[0].stop;
        if (stop == NONE) return 0;
        if (time > stream_time) {
            res = -1;
            p = time - stream_time;
        } else {
            res = 1;
            p = stream_time - time;
        }
        if (r != 1.0) p = divided(p, r);
        if (stop < p) {
            if (res == 1) {
                p -= stop;
                res = -1;
            } else {
                p +%= stop;
                res = 1;
            }
        } else {
            p = if (res == 1) stop - p else p +% stop;
            res = 1;
        }
    }
    out.* = p;
    return res;
}

pub export fn gst_segment_position_from_stream_time(s: [*c]const Seg, format: c.GstFormat, stream_time: c.guint64) c.guint64 {
    if (!check.that(s != null, "gst_segment_position_from_stream_time", "segment != NULL")) return NONE;
    if (!check.that(s[0].format == format, "gst_segment_position_from_stream_time", "segment->format == format")) return NONE;
    var p: u64 = 0;
    const res = gst_segment_position_from_stream_time_full(s, format, stream_time, &p);
    if (outside(s, p)) return NONE;
    return if (res == 1) p else NONE;
}

pub export fn gst_segment_to_running_time_full(s: [*c]const Seg, format: c.GstFormat, position: c.guint64, out: [*c]c.guint64) c.gint {
    if (position == NONE) {
        if (out != null) out.* = NONE;
        return 0;
    }
    if (!check.that(s != null, "gst_segment_to_running_time_full", "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, "gst_segment_to_running_time_full", "segment->format == format")) return 0;
    const offset = s[0].offset;
    var res: c.gint = undefined;
    var result: u64 = undefined;
    if (s[0].rate > 0.0) {
        const start = s[0].start +% offset;
        if (position < start) {
            result = start - position;
            res = -1;
        } else {
            result = position - start;
            res = 1;
        }
    } else {
        var stop = s[0].stop;
        if (stop == NONE and s[0].duration != NONE) stop = s[0].start +% s[0].duration;
        if (stop == NONE or stop < offset) return 0;
        stop -= offset;
        if (position > stop) {
            result = position - stop;
            res = -1;
        } else {
            result = stop - position;
            res = 1;
        }
    }
    if (out != null) {
        const r = @abs(s[0].rate);
        if (r != 1.0) result = divided(result, r);
        if (res == 1) {
            out.* = result +% s[0].base;
        } else if (s[0].base >= result) {
            out.* = s[0].base - result;
            res = 1;
        } else out.* = result - s[0].base;
    }
    return res;
}

pub export fn gst_segment_to_running_time(s: [*c]const Seg, format: c.GstFormat, position: c.guint64) c.guint64 {
    if (!check.that(s != null, "gst_segment_to_running_time", "segment != NULL")) return NONE;
    if (!check.that(s[0].format == format, "gst_segment_to_running_time", "segment->format == format")) return NONE;
    if (outside(s, position)) return NONE;
    var r: u64 = 0;
    return if (gst_segment_to_running_time_full(s, format, position, &r) == 1) r else NONE;
}

pub export fn gst_segment_clip(s: [*c]const Seg, format: c.GstFormat, start: c.guint64, stop: c.guint64, clip_start: [*c]c.guint64, clip_stop: [*c]c.guint64) c.gboolean {
    if (!check.that(s != null, "gst_segment_clip", "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, "gst_segment_clip", "segment->format == format")) return 0;
    if (s[0].stop != NONE and start != NONE and (start > s[0].stop or (s[0].start != s[0].stop and start == s[0].stop))) return 0;
    if (stop != NONE and (stop < s[0].start or (start != stop and stop == s[0].start))) return 0;
    if (clip_start != null) clip_start.* = if (start == NONE) NONE else @max(start, s[0].start);
    if (clip_stop != null) clip_stop.* = if (stop == NONE) s[0].stop else if (s[0].stop == NONE) stop else @min(stop, s[0].stop);
    return 1;
}

pub export fn gst_segment_position_from_running_time(s: [*c]const Seg, format: c.GstFormat, running: c.guint64) c.guint64 {
    if (!check.that(s != null, "gst_segment_position_from_running_time", "segment != NULL")) return NONE;
    if (!check.that(s[0].format == format, "gst_segment_position_from_running_time", "segment->format == format")) return NONE;
    var p: u64 = 0;
    if (gst_segment_position_from_running_time_full(s, format, running, &p) != 1) return NONE;
    if (outside(s, p)) return NONE;
    return p;
}

pub export fn gst_segment_position_from_running_time_full(s: [*c]const Seg, format: c.GstFormat, running: c.guint64, out: [*c]c.guint64) c.gint {
    if (running == NONE) {
        out.* = NONE;
        return 0;
    }
    if (!check.that(s != null, "gst_segment_position_from_running_time_full", "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, "gst_segment_position_from_running_time_full", "segment->format == format")) return 0;
    const base = s[0].base;
    const r = @abs(s[0].rate);
    const start = s[0].start;
    const stop = s[0].stop;
    const off = s[0].offset;
    var p: u64 = undefined;
    if (s[0].rate > 0.0) {
        if (running >= base) {
            p = running - base;
            if (r != 1.0) p = ceilTimes(p, r);
            out.* = p +% start +% off;
            return 1;
        }
        p = base - running;
        if (r != 1.0) p = ceilTimes(p, r);
        if (start +% off >= p) {
            out.* = start +% off -% p;
            return 1;
        }
        out.* = p -% (start +% off);
        return -1;
    }
    if (running >= base) {
        p = running - base;
        if (r != 1.0) p = ceilTimes(p, r);
        if (stop < p +% off) {
            out.* = p +% off -% stop;
            return -1;
        }
        out.* = stop -% p -% off;
        return 1;
    }
    p = base - running;
    if (r != 1.0) p = ceilTimes(p, r);
    if (stop +% p >= off) {
        out.* = stop +% p -% off;
        return 1;
    }
    out.* = off -% p -% stop;
    return -1;
}

pub export fn gst_segment_to_position(s: [*c]const Seg, format: c.GstFormat, running: c.guint64) c.guint64 {
    return gst_segment_position_from_running_time(s, format, running);
}

pub export fn gst_segment_set_running_time(s: [*c]Seg, format: c.GstFormat, running: c.guint64) c.gboolean {
    const p = gst_segment_position_from_running_time(s, format, running);
    if (p == NONE) return 0;
    var start = s[0].start;
    var stop = s[0].stop;
    if (s[0].rate > 0.0) start = p else stop = p;
    s[0].time = gst_segment_to_stream_time(s, format, start);
    s[0].start = start;
    s[0].stop = stop;
    s[0].base = running;
    return 1;
}

pub export fn gst_segment_offset_running_time(s: [*c]Seg, format: c.GstFormat, offset_in: c.gint64) c.gboolean {
    if (!check.that(s != null, "gst_segment_offset_running_time", "segment != NULL")) return 0;
    if (!check.that(s[0].format == format, "gst_segment_offset_running_time", "segment->format == format")) return 0;
    if (offset_in == 0) return 1;
    if (offset_in > 0) {
        s[0].base +%= @as(u64, @intCast(offset_in));
        return 1;
    }
    var offset: u64 = @bitCast(-%offset_in);
    if (s[0].base > offset) {
        s[0].base -= offset;
        return 1;
    }
    offset -= s[0].base;
    s[0].base = 0;
    const p = gst_segment_position_from_running_time(s, format, offset);
    if (p == NONE) return 0;
    s[0].offset = p -% s[0].start;
    return 1;
}

pub export fn gst_segment_is_equal(a: [*c]const Seg, b: [*c]const Seg) c.gboolean {
    const x = a.*;
    const y = b.*;
    return @intFromBool(x.flags == y.flags and x.rate == y.rate and x.applied_rate == y.applied_rate and x.format == y.format and x.base == y.base and x.offset == y.offset and x.start == y.start and x.stop == y.stop and x.time == y.time and x.position == y.position and x.duration == y.duration);
}

fn setField(st: [*c]c.GstStructure, name: [*c]const u8, t: c.GType, comptime setter: anytype, v: anytype) void {
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, t);
    setter(&gv, v);
    c.gst_structure_take_value_static_str(st, name, &gv);
}

pub fn toStructureString(seg: [*c]const Seg, quoted: bool) [*c]u8 {
    const st = c.gst_structure_new_static_str_empty("segment");
    const U = c.G_TYPE_UINT64;
    setField(st, "flags", c.gst_segment_flags_get_type(), c.g_value_set_flags, @as(c.guint, seg[0].flags));
    setField(st, "rate", c.G_TYPE_DOUBLE, c.g_value_set_double, seg[0].rate);
    setField(st, "applied-rate", c.G_TYPE_DOUBLE, c.g_value_set_double, seg[0].applied_rate);
    setField(st, "format", c.gst_format_get_type(), c.g_value_set_enum, @as(c.gint, @intCast(seg[0].format)));
    setField(st, "base", U, c.g_value_set_uint64, seg[0].base);
    setField(st, "offset", U, c.g_value_set_uint64, seg[0].offset);
    setField(st, "start", U, c.g_value_set_uint64, seg[0].start);
    setField(st, "stop", U, c.g_value_set_uint64, seg[0].stop);
    setField(st, "time", U, c.g_value_set_uint64, seg[0].time);
    setField(st, "position", U, c.g_value_set_uint64, seg[0].position);
    setField(st, "duration", U, c.g_value_set_uint64, seg[0].duration);
    const t = c.gst_structure_to_string(st);
    c.gst_structure_free(st);
    if (!quoted) return t;
    defer c.g_free(t);
    return c.g_strdup_printf("\"%s\"", t);
}

pub fn fromStructureString(dest: [*c]c.GValue, text: [*c]const u8, quoted: bool) bool {
    var st: [*c]c.GstStructure = null;
    if (quoted) {
        const len = std.mem.len(text);
        if (text[0] != '"' or len < 2 or text[len - 1] != '"') return false;
        const t = c.g_strdup(text + 1);
        t[len - 2] = 0;
        st = c.gst_structure_from_string(t, null);
        c.g_free(t);
    } else st = c.gst_structure_from_string(text, null);
    if (st == null) return false;
    defer c.gst_structure_free(st);
    var seg: Seg = undefined;
    const U = c.G_TYPE_UINT64;
    const ok = c.gst_structure_get(st, "flags", c.gst_segment_flags_get_type(), &seg.flags, "rate", c.G_TYPE_DOUBLE, &seg.rate, "applied-rate", c.G_TYPE_DOUBLE, &seg.applied_rate, "format", c.gst_format_get_type(), &seg.format, "base", U, &seg.base, "offset", U, &seg.offset, "start", U, &seg.start, "stop", U, &seg.stop, "time", U, &seg.time, "position", U, &seg.position, "duration", U, &seg.duration, @as(?*anyopaque, null));
    if (ok != 0) c.g_value_set_boxed(dest, &seg);
    return ok != 0;
}

fn serializeValue(v: [*c]const c.GValue) callconv(.c) [*c]u8 {
    return toStructureString(@ptrCast(@alignCast(c.g_value_get_boxed(v))), true);
}

fn deserializeValue(dest: [*c]c.GValue, s: [*c]const u8) callconv(.c) c.gboolean {
    return @intFromBool(fromStructureString(dest, s, true));
}

var value_table: c.GstValueTable = .{};


pub fn registerValue() void {
    value_table = .{ .type = gst_segment_get_type(), .serialize = serializeValue, .deserialize = deserializeValue, .hash = @import("vhash.zig").segment };
    value.gst_value_register(&value_table);
}
