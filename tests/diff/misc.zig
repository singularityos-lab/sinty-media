const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const NONE: u64 = std.math.maxInt(u64);

fn dumpSeg(label: []const u8, s: *const c.GstSegment) void {
    out("{s}: flags {d} rate {d} arate {d} fmt {d} base {d} off {d} start {d} stop {d} time {d} pos {d} dur {d}", .{ label, s.flags, s.rate, s.applied_rate, s.format, s.base, s.offset, s.start, s.stop, s.time, s.position, s.duration });
}

fn printFormat(item: [*c]const c.GValue, _: c.gpointer) callconv(.c) void {
    const d: *const c.GstFormatDefinition = @ptrCast(@alignCast(c.g_value_get_pointer(item)));
    out("format {d} {s} {s}", .{ d.value, str(d.nick), str(d.description) });
}

pub fn main() void {
    c.gst_init(null, null);
    out("formats {s} {s} {d}", .{ str(c.gst_format_get_name(c.GST_FORMAT_TIME)), str(c.gst_format_get_name(c.GST_FORMAT_BYTES)), c.gst_format_get_by_nick("percent") });
    const custom = c.gst_format_register("frames", "Video frames");
    out("register {d} again {d} name {s}", .{ custom, c.gst_format_register("frames", "x"), str(c.gst_format_get_name(custom)) });
    const it = c.gst_format_iterate_definitions();
    _ = c.gst_iterator_foreach(it, printFormat, null);
    c.gst_iterator_free(it);

    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    dumpSeg("init", &seg);
    seg.duration = 10 * std.time.ns_per_s;
    var update: c.gboolean = 0;
    const cases = [_]struct { f64, c_uint, c_uint, u64, c_uint, u64 }{
        .{ 1.0, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 2 * std.time.ns_per_s, c.GST_SEEK_TYPE_NONE, 0 },
        .{ 2.0, c.GST_SEEK_FLAG_SEGMENT | c.GST_SEEK_FLAG_TRICKMODE, c.GST_SEEK_TYPE_SET, 1 * std.time.ns_per_s, c.GST_SEEK_TYPE_SET, 5 * std.time.ns_per_s },
        .{ -1.0, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_NONE, 0, c.GST_SEEK_TYPE_END, 0 },
        .{ 0.5, 0, c.GST_SEEK_TYPE_END, @bitCast(@as(i64, -3 * std.time.ns_per_s)), c.GST_SEEK_TYPE_NONE, 0 },
        .{ 1.0, c.GST_SEEK_FLAG_KEY_UNIT, c.GST_SEEK_TYPE_SET, 20 * std.time.ns_per_s, c.GST_SEEK_TYPE_SET, 30 * std.time.ns_per_s },
    };
    for (cases, 0..) |cs, i| {
        const ok = c.gst_segment_do_seek(&seg, cs[0], c.GST_FORMAT_TIME, cs[1], cs[2], cs[3], cs[4], cs[5], &update);
        out("seek {d} ok {d} update {d}", .{ i, ok, update });
        dumpSeg("after", &seg);
        for ([_]u64{ 0, 1 * std.time.ns_per_s, 3 * std.time.ns_per_s, 7 * std.time.ns_per_s, NONE }) |p| {
            var rt: u64 = 0;
            var st: u64 = 0;
            var pos: u64 = 0;
            const r1 = c.gst_segment_to_running_time_full(&seg, c.GST_FORMAT_TIME, p, &rt);
            const r2 = c.gst_segment_to_stream_time_full(&seg, c.GST_FORMAT_TIME, p, &st);
            const r3 = c.gst_segment_position_from_running_time_full(&seg, c.GST_FORMAT_TIME, p, &pos);
            var cs1: u64 = 0;
            var cs2: u64 = 0;
            const clip = c.gst_segment_clip(&seg, c.GST_FORMAT_TIME, p, p +% std.time.ns_per_s, &cs1, &cs2);
            out("  p {d}: run {d}/{d} stream {d}/{d} pos {d}/{d} rt {d} st {d} fromst {d} clip {d} {d} {d}", .{ p, r1, rt, r2, st, r3, pos, c.gst_segment_to_running_time(&seg, c.GST_FORMAT_TIME, p), c.gst_segment_to_stream_time(&seg, c.GST_FORMAT_TIME, p), c.gst_segment_position_from_stream_time(&seg, c.GST_FORMAT_TIME, p), clip, cs1, cs2 });
        }
    }
    var s2: c.GstSegment = undefined;
    c.gst_segment_copy_into(&seg, &s2);
    out("equal {d} offset {d} setrt {d}", .{ c.gst_segment_is_equal(&seg, &s2), c.gst_segment_offset_running_time(&s2, c.GST_FORMAT_TIME, -500), c.gst_segment_set_running_time(&s2, c.GST_FORMAT_TIME, 2 * std.time.ns_per_s) });
    dumpSeg("s2", &s2);

    var sv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&sv, c.gst_segment_get_type());
    c.g_value_set_boxed(&sv, &seg);
    const ser = c.gst_value_serialize(&sv);
    out("segment ser {s}", .{str(ser)});
    var sv2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&sv2, c.gst_segment_get_type());
    out("segment deser {d}", .{c.gst_value_deserialize(&sv2, ser)});
    c.g_free(ser);

    const buf = c.gst_buffer_new_allocate(null, 4, null);
    _ = c.gst_buffer_memset(buf, 0, 0xab, 4);
    const cp = c.gst_caps_from_string("audio/x-raw, rate=(int)48000");
    const info = c.gst_structure_new_empty("info");
    c.gst_structure_set(info, "k", c.G_TYPE_INT, @as(c_int, 7), @as(?*anyopaque, null));
    const sample = c.gst_sample_new(buf, cp, &seg, info);
    out("sample buffer {d} caps {d} info {s}", .{ @intFromBool(c.gst_sample_get_buffer(sample) == buf), @intFromBool(c.gst_sample_get_caps(sample) == cp), str(c.gst_structure_to_string(c.gst_sample_get_info(sample))) });
    var smv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&smv, c.gst_sample_get_type());
    c.g_value_set_boxed(&smv, sample);
    const sser = c.gst_value_serialize(&smv);
    out("sample ser {s}", .{str(sser)});
    var smv2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&smv2, c.gst_sample_get_type());
    out("sample deser {d} cmp {d}", .{ c.gst_value_deserialize(&smv2, sser), c.gst_value_compare(&smv, &smv2) });
    const sample_copy = c.gst_sample_copy(sample);
    out("copy writable {d} orig writable {d}", .{ c.gst_sample_is_writable(sample_copy), c.gst_sample_is_writable(sample) });

    const dts = [_][*:0]const u8{ "2026-10-21T07:45:12.5+0200", "2026-10-21", "2026-10", "2026", "2026-10-21T07:45Z", "2026-10-21T07:45:12Z", "2026-10-21 23:59:59-05:30", "bogus", "1999-12-31T23:59:59.000123+01:00" };
    for (dts) |d| {
        const dt = c.gst_date_time_new_from_iso8601_string(d);
        if (dt == null) {
            out("dt {s}: null", .{d});
            continue;
        }
        const iso = c.gst_date_time_to_iso8601_string(dt);
        var dv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&dv, c.gst_date_time_get_type());
        c.g_value_set_boxed(&dv, dt);
        const vs = c.gst_value_serialize(&dv);
        out("dt {s}: iso {s} ser {s} y {d} m {d} d {d} h {d} mi {d} s {d} us {d} tz {d} has {d}{d}{d}{d}{d}", .{ d, str(iso), str(vs), c.gst_date_time_get_year(dt), c.gst_date_time_get_month(dt), c.gst_date_time_get_day(dt), c.gst_date_time_get_hour(dt), c.gst_date_time_get_minute(dt), c.gst_date_time_get_second(dt), c.gst_date_time_get_microsecond(dt), c.gst_date_time_get_time_zone_offset(dt), c.gst_date_time_has_year(dt), c.gst_date_time_has_month(dt), c.gst_date_time_has_day(dt), c.gst_date_time_has_time(dt), c.gst_date_time_has_second(dt) });
        c.g_free(iso);
        c.g_free(vs);
        c.g_value_unset(&dv);
        c.gst_date_time_unref(dt);
    }
    const nd = c.gst_date_time_new(-3.5, 2020, 2, 29, 12, 30, 15.25);
    out("new {s}", .{str(c.gst_date_time_to_iso8601_string(nd))});
    out("invalid {d} {d}", .{ @intFromBool(c.gst_date_time_new(13.0, 2020, 1, 1, 0, 0, 0) == null), @intFromBool(c.gst_date_time_new_ymd(2020, 13, 1) == null) });

    const ctx = c.gst_context_new("gst.gl.GLDisplay", 1);
    const ws = c.gst_context_writable_structure(ctx);
    c.gst_structure_set(ws, "display", c.G_TYPE_STRING, "wayland-0", @as(?*anyopaque, null));
    const ctx2 = c.gst_context_copy(ctx);
    out("context {s} {d} {d} {s}", .{ str(c.gst_context_get_context_type(ctx2)), c.gst_context_has_context_type(ctx2, "gst.gl.GLDisplay"), c.gst_context_is_persistent(ctx2), str(c.gst_structure_to_string(c.gst_context_get_structure(ctx2))) });

    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_STRING);
    c.g_value_set_string(&v, "single");
    const single = c.gst_iterator_new_single(c.G_TYPE_STRING, &v);
    var item = std.mem.zeroes(c.GValue);
    var n: c_int = 0;
    while (c.gst_iterator_next(single, &item) == c.GST_ITERATOR_OK) : (n += 1) out("single item {s}", .{str(c.g_value_get_string(&item))});
    c.gst_iterator_resync(single);
    out("single resync next {d}", .{c.gst_iterator_next(single, &item)});
    c.gst_iterator_free(single);
}
