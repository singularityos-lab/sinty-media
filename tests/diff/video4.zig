const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const NONE = @as(?*anyopaque, null);
const TC = c.GstVideoTimeCode;

fn tcs(t: [*c]const TC) []const u8 {
    const S = struct {
        var buf: [8][64]u8 = undefined;
        var n: usize = 0;
    };
    if (t == null) return "(null)";
    const s = c.gst_video_time_code_to_string(t);
    S.n = (S.n + 1) % 8;
    const r = std.fmt.bufPrint(&S.buf[S.n], "{s}@{d}/{d}f{d}fc{d}", .{ str(s), t[0].config.fps_n, t[0].config.fps_d, t[0].config.flags, t[0].field_count }) catch "?";
    c.g_free(s);
    return r;
}

fn dtStr(d: ?*c.GDateTime) []const u8 {
    const S = struct {
        var buf: [4][96]u8 = undefined;
        var n: usize = 0;
    };
    if (d == null) return "(null)";
    const s = c.g_date_time_format(d, "%Y-%m-%d %H:%M:%S.%f %z");
    S.n = (S.n + 1) % 4;
    const r = std.fmt.bufPrint(&S.buf[S.n], "{s}", .{str(s)}) catch "?";
    c.g_free(s);
    return r;
}

const rates = [_][2]c.guint{ .{ 0, 1 }, .{ 1, 0 }, .{ 25, 1 }, .{ 30, 1 }, .{ 50, 1 }, .{ 60, 1 }, .{ 30000, 1001 }, .{ 60000, 1001 }, .{ 120000, 1001 }, .{ 24000, 1001 }, .{ 48000, 1001 }, .{ 1, 2 }, .{ 1, 3 }, .{ 2, 3 }, .{ 25, 2 }, .{ 1, 60 } };
const flagsets = [_]c.guint{ 0, c.GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME, c.GST_VIDEO_TIME_CODE_FLAGS_INTERLACED, c.GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME | c.GST_VIDEO_TIME_CODE_FLAGS_INTERLACED };
const times = [_][4]c.guint{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 1 }, .{ 0, 1, 0, 0 }, .{ 0, 1, 0, 1 }, .{ 0, 1, 0, 2 }, .{ 0, 1, 0, 4 }, .{ 0, 10, 0, 0 }, .{ 1, 2, 3, 4 }, .{ 23, 59, 59, 24 }, .{ 23, 59, 59, 29 }, .{ 23, 59, 59, 59 }, .{ 24, 0, 0, 0 }, .{ 0, 60, 0, 0 }, .{ 0, 0, 60, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 2, 0 }, .{ 0, 0, 3, 0 }, .{ 0, 0, 59, 0 }, .{ 12, 34, 56, 7 } };

fn timecodes() void {
    out("timecode", .{});
    const jam = c.g_date_time_new_utc(2024, 2, 29, 0, 0, 0.0);
    for (rates) |r| for (flagsets) |fl| for (times) |t| for ([_]c.guint{ 0, 1, 2 }) |fc| {
        var tc: TC = std.mem.zeroes(TC);
        c.gst_video_time_code_init(&tc, r[0], r[1], null, fl, t[0], t[1], t[2], t[3], fc);
        const ok = c.gst_video_time_code_is_valid(&tc);
        if (ok == 0) {
            out("  {s} invalid", .{tcs(&tc)});
            continue;
        }
        const frames = c.gst_video_time_code_frames_since_daily_jam(&tc);
        const ns = c.gst_video_time_code_nsec_since_daily_jam(&tc);
        var line: [512]u8 = undefined;
        var n: usize = 0;
        for ([_]c_long{ 1, 2, 17, 1798, 1800, 17982, 107892, 2592000, -1, 0 }) |d| {
            var t2 = tc;
            c.gst_video_time_code_add_frames(&t2, d);
            const w = std.fmt.bufPrint(line[n..], "{d}:{s} ", .{ d, tcs(&t2) }) catch break;
            n += w.len;
        }
        out("  {s} frames {d} ns {d} adds {s}", .{ tcs(&tc), frames, ns, line[0..n] });
        var tj = tc;
        tj.config.latest_daily_jam = jam;
        const dt = c.gst_video_time_code_to_date_time(&tj);
        out("    dt {s}", .{dtStr(dt)});
        if (dt != null) c.g_date_time_unref(dt);
        var t3 = tc;
        c.gst_video_time_code_increment_frame(&t3);
        out("    inc {s} cmp {d} {d} {d}", .{ tcs(&t3), c.gst_video_time_code_compare(&tc, &t3), c.gst_video_time_code_compare(&t3, &tc), c.gst_video_time_code_compare(&tc, &tc) });
        for ([_][4]c.guint{ .{ 0, 0, 0, 1 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 59, 28 }, .{ 1, 0, 0, 0 }, .{ 0, 9, 0, 0 }, .{ 0, 0, 0, 30 } }) |iv| {
            var inter: c.GstVideoTimeCodeInterval = undefined;
            c.gst_video_time_code_interval_init(&inter, iv[0], iv[1], iv[2], iv[3]);
            const sum = c.gst_video_time_code_add_interval(&tc, &inter);
            out("    +{any} {s}", .{ iv, tcs(sum) });
            if (sum != null) c.gst_video_time_code_free(sum);
        }
    };
    var a: TC = std.mem.zeroes(TC);
    var b: TC = std.mem.zeroes(TC);
    c.gst_video_time_code_init(&a, 25, 1, jam, 0, 1, 2, 3, 4, 0);
    c.gst_video_time_code_init(&b, 25, 1, jam, 0, 1, 2, 3, 5, 0);
    out("  cmp jam {d} {d}", .{ c.gst_video_time_code_compare(&a, &b), c.gst_video_time_code_compare(&b, &a) });
    const cp = c.gst_video_time_code_copy(&a);
    out("  copy {s} jam {any}", .{ tcs(cp), cp[0].config.latest_daily_jam == jam });
    c.gst_video_time_code_free(cp);
    c.gst_video_time_code_clear(&a);
    c.gst_video_time_code_clear(&b);
    out("  cleared {s}", .{tcs(&a)});
    _ = c.gst_video_time_code_compare(&a, &b);
    _ = c.gst_video_time_code_is_valid(null);
    _ = c.gst_video_time_code_frames_since_daily_jam(&a);
    _ = c.gst_video_time_code_to_date_time(&a);
    for ([_][*c]const u8{ "01:02:03:04", "01:02:03.04", "01:02:03;04", "01:02:03,04", "1:2:3:4", "123:45:67:89", "01:02:03", "aa:bb:cc:dd", "", "00:00:00:00", "23:59:59;29", "001:02:03:04" }) |s| {
        const t = c.gst_video_time_code_new_from_string(s);
        const i = c.gst_video_time_code_interval_new_from_string(s);
        out("  parse {s} -> {s} interval {any}", .{ str(s), tcs(t), if (i != null) [4]c.guint{ i[0].hours, i[0].minutes, i[0].seconds, i[0].frames } else [4]c.guint{ 9, 9, 9, 9 } });
        if (t != null) c.gst_video_time_code_free(t);
        if (i != null) {
            const ic = c.gst_video_time_code_interval_copy(i);
            c.gst_video_time_code_interval_clear(i);
            out("    icopy {d} cleared {d}", .{ ic[0].minutes, i[0].minutes });
            c.gst_video_time_code_interval_free(ic);
            c.gst_video_time_code_interval_free(i);
        }
    }
    for ([_]c_int{ 0, 1, 500000, 999999, 966666, 33333, 40000 }) |us| for ([_][2]c.guint{ .{ 25, 1 }, .{ 30, 1 }, .{ 30000, 1001 }, .{ 60000, 1001 }, .{ 1, 2 }, .{ 24000, 1001 }, .{ 25, 2 } }) |r| for ([_]c.guint{ 0, c.GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME }) |fl| {
        const dt = c.g_date_time_new_utc(2023, 7, 14, 13, 1, 0.0 + @as(f64, @floatFromInt(us)) / 1000000.0);
        const t = c.gst_video_time_code_new_from_date_time_full(r[0], r[1], dt, fl, 0);
        const t2 = c.gst_video_time_code_new_from_date_time(r[0], r[1], dt, fl, 1);
        out("  fromdt {d} {any} {d} -> {s} / {s}", .{ us, r, fl, tcs(t), tcs(t2) });
        if (t != null) c.gst_video_time_code_free(t);
        c.gst_video_time_code_free(t2);
        c.g_date_time_unref(dt);
    };
    const e = c.gst_video_time_code_new_empty();
    out("  empty {s}", .{tcs(e)});
    c.gst_video_time_code_free(e);
    _ = c.gst_video_time_code_init_from_date_time_full(null, 1, 1, jam, 0, 0);
    var tmp: TC = std.mem.zeroes(TC);
    _ = c.gst_video_time_code_init_from_date_time_full(&tmp, 0, 1, jam, 0, 0);
    _ = c.gst_video_time_code_init_from_date_time_full(&tmp, 1, 1, null, 0, 0);
    c.gst_video_time_code_init_from_date_time(&tmp, 25, 2, jam, 0, 0);
    out("  bad init {s}", .{tcs(&tmp)});
    var gv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&gv, c.gst_video_time_code_get_type());
    const vt = c.gst_video_time_code_new(30000, 1001, null, c.GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME, 1, 2, 3, 4, 0);
    c.g_value_take_boxed(&gv, vt);
    var sv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&sv, c.G_TYPE_STRING);
    out("  transform {d} {s}", .{ c.g_value_transform(&gv, &sv), str(c.g_value_get_string(&sv)) });
    const ser = c.gst_value_serialize(&gv);
    out("  serialize {s}", .{str(ser)});
    c.g_free(ser);
    var dv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&dv, c.gst_video_time_code_get_type());
    out("  deserialize {d} {s}", .{ c.gst_value_deserialize(&dv, "11:22:33:12"), tcs(@ptrCast(@alignCast(c.g_value_get_boxed(&dv)))) });
    out("  deserialize bad {d}", .{c.gst_value_deserialize(&dv, "xx")});
    var back = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&back, c.gst_video_time_code_get_type());
    c.g_value_set_string(&sv, "05:06:07,08");
    out("  from string {d} {s}", .{ c.g_value_transform(&sv, &back), tcs(@ptrCast(@alignCast(c.g_value_get_boxed(&back)))) });
    const st = c.gst_structure_from_string("t, tc=(GstVideoTimeCode)01:00:00:00", null);
    const sts = c.gst_structure_to_string(st);
    out("  structure {s}", .{str(sts)});
    c.g_free(sts);
    c.gst_structure_free(st);
    out("  types {s} {s}", .{ str(c.g_type_name(c.gst_video_time_code_get_type())), str(c.g_type_name(c.gst_video_time_code_interval_get_type())) });
    c.g_value_unset(&gv);
    c.g_value_unset(&sv);
    c.g_value_unset(&dv);
    c.g_value_unset(&back);
    c.g_date_time_unref(jam);
}

fn showVMeta(label: []const u8, m: [*c]c.GstVideoMeta) void {
    if (m == null) {
        out("  {s} (null)", .{label});
        return;
    }
    out("  {s} fl {d} fmt {d} id {d} {d}x{d} np {d} off {any} stride {any} align {d},{d},{d},{d} {any}", .{ label, m[0].flags, m[0].format, m[0].id, m[0].width, m[0].height, m[0].n_planes, m[0].offset, m[0].stride, m[0].alignment.padding_top, m[0].alignment.padding_bottom, m[0].alignment.padding_left, m[0].alignment.padding_right, m[0].alignment.stride_align });
}

var upload_calls: u32 = 0;
var copies: u32 = 0;
var frees: u32 = 0;

fn uploadFn(_: [*c]c.GstVideoGLTextureUploadMeta, ids: [*c]c.guint) callconv(.c) c.gboolean {
    upload_calls += 1;
    return @intFromBool(ids[0] == 7);
}

fn udCopy(p: c.gpointer) callconv(.c) c.gpointer {
    copies += 1;
    return p;
}

fn udFree(_: c.gpointer) callconv(.c) void {
    frees += 1;
}

fn listMetas(label: []const u8, b: [*c]c.GstBuffer) void {
    var state: c.gpointer = null;
    var line: [1024]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const m = c.gst_buffer_iterate_meta(b, &state);
        if (m == null) break;
        const w = std.fmt.bufPrint(line[n..], "{s} ", .{str(c.g_type_name(m[0].info[0].api))}) catch break;
        n += w.len;
    }
    out("  {s} metas: {s}", .{ label, line[0..n] });
}

fn metas() void {
    out("meta", .{});
    out("  api {s} {s} {s} {s} {s} {s} {s}", .{ str(c.g_type_name(c.gst_video_meta_api_get_type())), str(c.g_type_name(c.gst_video_crop_meta_api_get_type())), str(c.g_type_name(c.gst_video_region_of_interest_meta_api_get_type())), str(c.g_type_name(c.gst_video_gl_texture_upload_meta_api_get_type())), str(c.g_type_name(c.gst_video_time_code_meta_api_get_type())), str(c.g_type_name(c.gst_video_codec_alpha_meta_api_get_type())), str(c.g_type_name(c.gst_video_affine_transformation_meta_api_get_type())) });
    for ([_]c.GType{ c.gst_video_meta_api_get_type(), c.gst_video_crop_meta_api_get_type(), c.gst_video_region_of_interest_meta_api_get_type(), c.gst_video_affine_transformation_meta_api_get_type() }) |api| {
        const tags = c.gst_meta_api_type_get_tags(api);
        var line: [256]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (tags[i] != null) : (i += 1) {
            const w = std.fmt.bufPrint(line[n..], "{s} ", .{str(tags[i])}) catch break;
            n += w.len;
        }
        out("  tags {s}: {s}", .{ str(c.g_type_name(api)), line[0..n] });
    }
    out("  infos {s} {s} {s} {s} {s} {s} {s}", .{ str(c.g_type_name(c.gst_video_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_crop_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_region_of_interest_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_gl_texture_upload_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_time_code_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_codec_alpha_meta_get_info()[0].type)), str(c.g_type_name(c.gst_video_affine_transformation_meta_get_info()[0].type)) });
    out("  sizes {d} {d} {d}", .{ c.gst_video_meta_get_info()[0].size, c.gst_video_crop_meta_get_info()[0].size, c.gst_video_region_of_interest_meta_get_info()[0].size });
    var vi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&vi, c.GST_VIDEO_FORMAT_I420, 64, 48);
    const buf = c.gst_buffer_new_allocate(null, vi.size, null);
    const vm = c.gst_buffer_add_video_meta(buf, c.GST_VIDEO_FRAME_FLAG_INTERLACED, c.GST_VIDEO_FORMAT_I420, 64, 48);
    showVMeta("added", vm);
    showVMeta("get", c.gst_buffer_get_video_meta(buf));
    showVMeta("get id0", c.gst_buffer_get_video_meta_id(buf, 0));
    showVMeta("get id1", c.gst_buffer_get_video_meta_id(buf, 1));
    showVMeta("bad fmt", c.gst_buffer_add_video_meta(buf, 0, c.GST_VIDEO_FORMAT_UNKNOWN, 1, 1));
    const vm2 = c.gst_buffer_add_video_meta(buf, 0, c.GST_VIDEO_FORMAT_I420, 32, 24);
    vm2[0].id = 2;
    const vm3 = c.gst_buffer_add_video_meta(buf, 0, c.GST_VIDEO_FORMAT_I420, 16, 12);
    vm3[0].id = 1;
    vm[0].id = 5;
    showVMeta("lowest id", c.gst_buffer_get_video_meta(buf));
    showVMeta("id 2", c.gst_buffer_get_video_meta_id(buf, 2));
    vm[0].id = 0;
    for (0..3) |p| {
        var mi: c.GstMapInfo = undefined;
        var data: c.gpointer = null;
        var stride: c.gint = 0;
        const ok = c.gst_video_meta_map(vm, @intCast(p), &mi, &data, &stride, c.GST_MAP_READ);
        out("  map {d} -> {d} off {d} stride {d}", .{ p, ok, @intFromPtr(data) - @intFromPtr(mi.data), stride });
        if (ok != 0) _ = c.gst_video_meta_unmap(vm, @intCast(p), &mi);
    }
    var mi: c.GstMapInfo = undefined;
    var data: c.gpointer = null;
    var stride: c.gint = 0;
    _ = c.gst_video_meta_map(vm, 3, &mi, &data, &stride, c.GST_MAP_READ);
    _ = c.gst_video_meta_map(null, 0, &mi, &data, &stride, c.GST_MAP_READ);
    _ = c.gst_video_meta_unmap(vm, 5, &mi);
    _ = c.gst_buffer_ref(buf);
    _ = c.gst_video_meta_map(vm, 0, &mi, &data, &stride, c.GST_MAP_WRITE);
    c.gst_buffer_unref(buf);
    var al = std.mem.zeroes(c.GstVideoAlignment);
    out("  align zero {d}", .{c.gst_video_meta_set_alignment(vm, al)});
    al.padding_right = 16;
    out("  align bad {d}", .{c.gst_video_meta_set_alignment(vm, al)});
    al.padding_right = 0;
    al.stride_align = .{ 3, 1, 1, 0 };
    out("  align ok {d}", .{c.gst_video_meta_set_alignment_full(vm, &al)});
    showVMeta("aligned", vm);
    var ps: [4]c.gsize = .{ 9, 9, 9, 9 };
    var ph: [4]c.guint = .{ 9, 9, 9, 9 };
    out("  plane size {d} {any} height {d} {any}", .{ c.gst_video_meta_get_plane_size(vm, &ps), ps, c.gst_video_meta_get_plane_height(vm, &ph), ph });
    _ = c.gst_video_meta_get_plane_size(null, &ps);
    _ = c.gst_video_meta_get_plane_height(vm, null);
    listMetas("orig", buf);
    const copy = c.gst_buffer_copy(buf);
    listMetas("copy", copy);
    showVMeta("copied", c.gst_buffer_get_video_meta(copy));
    const region = c.gst_buffer_copy_region(buf, c.GST_BUFFER_COPY_ALL, 10, 100);
    listMetas("region", region);
    var ser = c.g_byte_array_new();
    out("  serialize {d} len {d}", .{ c.gst_meta_serialize_simple(@ptrCast(vm), ser), ser[0].len });
    var hash: u32 = 0;
    for (ser[0].data[0..ser[0].len]) |b| hash = hash *% 31 +% b;
    out("  serialized hash {x}", .{hash});
    const dest = c.gst_buffer_new_allocate(null, vi.size, null);
    var consumed: u32 = 0;
    const dm = c.gst_meta_deserialize(dest, ser[0].data, ser[0].len, &consumed);
    out("  deserialize {any} consumed {d}", .{ dm != null, consumed });
    showVMeta("deser", @ptrCast(@alignCast(dm)));
    _ = c.g_byte_array_set_size(ser, 0);
    vm2[0].map = vm[0].map;
    out("  serialize custom {d}", .{c.gst_meta_serialize_simple(@ptrCast(vm3), ser)});
    c.g_byte_array_unref(ser);
    c.gst_buffer_unref(dest);
    c.gst_buffer_unref(region);
    c.gst_buffer_unref(copy);
    c.gst_buffer_unref(buf);

    const multi = c.gst_buffer_new();
    c.gst_buffer_append_memory(multi, c.gst_allocator_alloc(null, vi.offset[1], null));
    c.gst_buffer_append_memory(multi, c.gst_allocator_alloc(null, vi.size - vi.offset[1], null));
    const mm = c.gst_buffer_add_video_meta_full(multi, 0, c.GST_VIDEO_FORMAT_I420, 64, 48, 3, &vi.offset, &vi.stride);
    for (0..3) |p| {
        const ok = c.gst_video_meta_map(mm, @intCast(p), &mi, &data, &stride, c.GST_MAP_READ);
        out("  multi map {d} -> {d} off {d} size {d}", .{ p, ok, @intFromPtr(data) - @intFromPtr(mi.data), mi.size });
        if (ok != 0) _ = c.gst_video_meta_unmap(mm, @intCast(p), &mi);
    }
    var far = vi.offset;
    far[2] = 1 << 20;
    const fm = c.gst_buffer_add_video_meta_full(multi, 0, c.GST_VIDEO_FORMAT_I420, 64, 48, 3, &far, &vi.stride);
    out("  far map {d}", .{c.gst_video_meta_map(fm, 2, &mi, &data, &stride, c.GST_MAP_READ)});
    c.gst_buffer_unref(multi);

    var in_info: c.GstVideoInfo = undefined;
    var out_info: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&in_info, c.GST_VIDEO_FORMAT_RGBA, 640, 480);
    _ = c.gst_video_info_set_format(&out_info, c.GST_VIDEO_FORMAT_RGBA, 320, 200);
    const b2 = c.gst_buffer_new();
    const crop: [*c]c.GstVideoCropMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b2, c.gst_video_crop_meta_get_info(), null)));
    out("  crop init {d} {d} {d} {d}", .{ crop[0].x, crop[0].y, crop[0].width, crop[0].height });
    crop[0].x = 10;
    crop[0].y = 21;
    crop[0].width = 333;
    crop[0].height = 401;
    const roi = c.gst_buffer_add_video_region_of_interest_meta(b2, "face", 100, 50, 200, 300);
    roi[0].id = 3;
    roi[0].parent_id = 1;
    c.gst_video_region_of_interest_meta_add_param(roi, c.gst_structure_new("detect", "conf", c.G_TYPE_DOUBLE, @as(f64, 0.5), NONE));
    c.gst_video_region_of_interest_meta_add_param(roi, c.gst_structure_new_empty("track"));
    const p1 = c.gst_video_region_of_interest_meta_get_param(roi, "track");
    out("  roi param {s} {any}", .{ str(c.gst_structure_get_name(p1)), c.gst_video_region_of_interest_meta_get_param(roi, "x") == null });
    const roi2 = c.gst_buffer_add_video_region_of_interest_meta_id(b2, c.g_quark_from_string("car"), 600, 400, 100, 100);
    roi2[0].id = 4;
    out("  roi get {any} {any}", .{ c.gst_buffer_get_video_region_of_interest_meta_id(b2, 4) == roi2, c.gst_buffer_get_video_region_of_interest_meta_id(b2, 9) == null });
    var aff = c.gst_buffer_add_video_affine_transformation_meta(b2);
    out("  affine init {any}", .{aff[0].matrix});
    const rot = [16]f32{ 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0.5, 0.25, 0, 1 };
    c.gst_video_affine_transformation_meta_apply_matrix(aff, &rot);
    c.gst_video_affine_transformation_meta_apply_matrix(aff, &rot);
    const sc = [16]f32{ 0.3, 0, 0, 0, 0, 0.7, 0, 0, 0, 0, 1, 0, 0.1, 0.2, 0, 1 };
    c.gst_video_affine_transformation_meta_apply_matrix(aff, &sc);
    out("  affine applied {any}", .{aff[0].matrix});
    var types = [4]c.GstVideoGLTextureType{ 1, 2, 3, 4 };
    const up = c.gst_buffer_add_video_gl_texture_upload_meta(b2, c.GST_VIDEO_GL_TEXTURE_ORIENTATION_X_FLIP_Y_NORMAL, 2, &types, uploadFn, @ptrFromInt(0x1234), udCopy, udFree);
    var ids = [4]c.guint{ 7, 8, 9, 10 };
    out("  upload {d} {d}", .{ c.gst_video_gl_texture_upload_meta_upload(up, &ids), upload_calls });
    _ = c.gst_buffer_add_video_gl_texture_upload_meta(b2, 0, 0, &types, uploadFn, null, null, null);
    _ = c.gst_buffer_add_video_gl_texture_upload_meta(b2, 0, 1, &types, null, null, null, null);
    var tc: TC = std.mem.zeroes(TC);
    c.gst_video_time_code_init(&tc, 25, 1, null, 0, 10, 11, 12, 13, 0);
    const tm = c.gst_buffer_add_video_time_code_meta(b2, &tc);
    out("  tcmeta {s}", .{tcs(&tm[0].tc)});
    out("  tcmeta bad {any} {any}", .{ c.gst_buffer_add_video_time_code_meta_full(b2, 25, 1, null, 0, 30, 0, 0, 0, 0) == null, blk: {
        var bad = tc;
        bad.frames = 99;
        break :blk c.gst_buffer_add_video_time_code_meta(b2, &bad) == null;
    } });
    const alpha = c.gst_buffer_new_allocate(null, 16, null);
    const am = c.gst_buffer_add_video_codec_alpha_meta(b2, alpha);
    out("  alpha {any} rc {d}", .{ am[0].buffer == alpha, alpha[0].mini_object.refcount });
    listMetas("b2", b2);
    const b3 = c.gst_buffer_copy(b2);
    listMetas("b3", b3);
    out("  copies {d} frees {d} alpha rc {d}", .{ copies, frees, alpha[0].mini_object.refcount });
    var st: c.gpointer = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta(b3, &st);
        if (m == null) break;
        const api = m[0].info[0].api;
        if (api == c.gst_video_crop_meta_api_get_type()) {
            const cm: [*c]c.GstVideoCropMeta = @ptrCast(@alignCast(m));
            out("  b3 crop {d} {d} {d} {d}", .{ cm[0].x, cm[0].y, cm[0].width, cm[0].height });
        } else if (api == c.gst_video_region_of_interest_meta_api_get_type()) {
            const rm: [*c]c.GstVideoRegionOfInterestMeta = @ptrCast(@alignCast(m));
            out("  b3 roi {s} {d} {d} {d}x{d}+{d}+{d} params {d}", .{ str(c.g_quark_to_string(rm[0].roi_type)), rm[0].id, rm[0].parent_id, rm[0].w, rm[0].h, rm[0].x, rm[0].y, c.g_list_length(rm[0].params) });
        } else if (api == c.gst_video_affine_transformation_meta_api_get_type()) {
            const fm2: [*c]c.GstVideoAffineTransformationMeta = @ptrCast(@alignCast(m));
            out("  b3 affine {any}", .{fm2[0].matrix});
        } else if (api == c.gst_video_gl_texture_upload_meta_api_get_type()) {
            const um: [*c]c.GstVideoGLTextureUploadMeta = @ptrCast(@alignCast(m));
            out("  b3 upload {d} {d} {any} {any}", .{ um[0].texture_orientation, um[0].n_textures, um[0].texture_type, um[0].buffer == b3 });
        } else if (api == c.gst_video_time_code_meta_api_get_type()) {
            const tm2: [*c]c.GstVideoTimeCodeMeta = @ptrCast(@alignCast(m));
            out("  b3 tc {s}", .{tcs(&tm2[0].tc)});
        }
    }
    var trans = c.GstVideoMetaTransform{ .in_info = &in_info, .out_info = &out_info };
    const sq = c.gst_video_meta_transform_scale_get_quark();
    const b4 = c.gst_buffer_new();
    out("  scale crop {d}", .{c.gst_video_crop_meta_get_info()[0].transform_func.?(b4, @ptrCast(crop), b2, sq, &trans)});
    out("  scale roi {d}", .{c.gst_video_region_of_interest_meta_get_info()[0].transform_func.?(b4, @ptrCast(roi), b2, sq, &trans)});
    out("  bogus roi {d}", .{c.gst_video_region_of_interest_meta_get_info()[0].transform_func.?(b4, @ptrCast(roi), b2, c.g_quark_from_string("x"), &trans)});
    out("  bogus crop {d}", .{c.gst_video_crop_meta_get_info()[0].transform_func.?(b4, @ptrCast(crop), b2, c.g_quark_from_string("x"), &trans)});
    out("  bogus vmeta {d}", .{c.gst_video_meta_get_info()[0].transform_func.?(b4, @ptrCast(crop), b2, sq, &trans)});
    for ([_][4]c.gint{ .{ 0, 0, 640, 480 }, .{ 100, 50, 200, 100 }, .{ 0, 0, 1, 1 } }) |ir| for ([_][4]c.gint{ .{ 0, 0, 320, 200 }, .{ 10, 20, 100, 50 }, .{ 5, 5, 1000, 3 } }) |orr| {
        var mt: c.GstVideoMetaTransformMatrix = undefined;
        const in_r = c.GstVideoRectangle{ .x = ir[0], .y = ir[1], .w = ir[2], .h = ir[3] };
        const out_r = c.GstVideoRectangle{ .x = orr[0], .y = orr[1], .w = orr[2], .h = orr[3] };
        c.gst_video_meta_transform_matrix_init(&mt, &in_info, &in_r, &out_info, &out_r);
        out("  matrix {any} {any}: {any}", .{ ir, orr, mt.matrix });
        for ([_][2]c.gint{ .{ 0, 0 }, .{ 100, 50 }, .{ 639, 479 }, .{ 640, 480 }, .{ -5, 10 }, .{ 333, 777 } }) |pt| {
            var x = pt[0];
            var y = pt[1];
            const ok = c.gst_video_meta_transform_matrix_point(&mt, &x, &y);
            var x2 = pt[0];
            var y2 = pt[1];
            const ok2 = c.gst_video_meta_transform_matrix_point_clipped(&mt, &x2, &y2);
            out("   pt {any} -> {d} {d},{d} clip {d} {d},{d}", .{ pt, ok, x, y, ok2, x2, y2 });
        }
        var r1 = c.GstVideoRectangle{ .x = 100, .y = 50, .w = 200, .h = 300 };
        var r2 = r1;
        out("   rect {d} {d},{d},{d},{d} clip {d} {d},{d},{d},{d}", .{ c.gst_video_meta_transform_matrix_rectangle(&mt, &r1), r1.x, r1.y, r1.w, r1.h, c.gst_video_meta_transform_matrix_rectangle_clipped(&mt, &r2), r2.x, r2.y, r2.w, r2.h });
        const mq = c.gst_video_meta_transform_matrix_get_quark();
        const b5 = c.gst_buffer_new();
        out("   roi matrix {d}", .{c.gst_video_region_of_interest_meta_get_info()[0].transform_func.?(b5, @ptrCast(roi), b2, mq, &mt)});
        mt.matrix[0][1] = 0.5;
        out("   roi shear {d}", .{c.gst_video_region_of_interest_meta_get_info()[0].transform_func.?(b5, @ptrCast(roi), b2, mq, &mt)});
        mt.matrix[2][0] = 0.001;
        var x = @as(c.gint, 10);
        var y = @as(c.gint, 10);
        out("   projective {d} {d},{d}", .{ c.gst_video_meta_transform_matrix_point(&mt, &x, &y), x, y });
        mt.matrix[2][2] = 0;
        mt.matrix[2][0] = 0;
        x = 0;
        y = 0;
        out("   degenerate {d} {d},{d}", .{ c.gst_video_meta_transform_matrix_point(&mt, &x, &y), x, y });
        st = null;
        while (true) {
            const m = c.gst_buffer_iterate_meta(b5, &st);
            if (m == null) break;
            const rm: [*c]c.GstVideoRegionOfInterestMeta = @ptrCast(@alignCast(m));
            out("   b5 roi {d} {d} {d}x{d}+{d}+{d}", .{ rm[0].id, rm[0].parent_id, rm[0].w, rm[0].h, rm[0].x, rm[0].y });
        }
        c.gst_buffer_unref(b5);
    };
    st = null;
    while (true) {
        const m = c.gst_buffer_iterate_meta(b4, &st);
        if (m == null) break;
        if (m[0].info[0].api == c.gst_video_crop_meta_api_get_type()) {
            const cm: [*c]c.GstVideoCropMeta = @ptrCast(@alignCast(m));
            out("  b4 crop {d} {d} {d} {d}", .{ cm[0].x, cm[0].y, cm[0].width, cm[0].height });
        } else {
            const rm: [*c]c.GstVideoRegionOfInterestMeta = @ptrCast(@alignCast(m));
            out("  b4 roi {d} {d} {d}x{d}+{d}+{d}", .{ rm[0].id, rm[0].parent_id, rm[0].w, rm[0].h, rm[0].x, rm[0].y });
        }
    }
    _ = c.gst_buffer_add_video_region_of_interest_meta_id(null, 0, 0, 0, 0, 0);
    _ = c.gst_buffer_add_video_affine_transformation_meta(null);
    _ = c.gst_buffer_add_video_codec_alpha_meta(b2, null);
    c.gst_video_region_of_interest_meta_add_param(roi, null);
    _ = c.gst_video_region_of_interest_meta_get_param(roi, null);
    c.gst_buffer_unref(b4);
    c.gst_buffer_unref(b3);
    c.gst_buffer_unref(b2);
    out("  after free copies {d} frees {d}", .{ copies, frees });
    aff = null;
    var config = c.gst_structure_new_empty("video-meta");
    var a2 = std.mem.zeroes(c.GstVideoAlignment);
    a2.padding_top = 1;
    a2.padding_left = 3;
    a2.stride_align = .{ 15, 7, 7, 0 };
    c.gst_buffer_pool_config_set_video_alignment(config, &a2);
    const cs = c.gst_structure_to_string(config);
    out("  align config {s}", .{str(cs)});
    c.g_free(cs);
    var a3: c.GstVideoAlignment = undefined;
    @memset(std.mem.asBytes(&a3), 0x11);
    out("  get align {d} {d} {d} {any}", .{ c.gst_buffer_pool_config_get_video_alignment(config, &a3), a3.padding_top, a3.padding_left, a3.stride_align });
    c.gst_structure_remove_field(config, "stride-align3");
    out("  get partial {d}", .{c.gst_buffer_pool_config_get_video_alignment(config, &a3)});
    c.gst_buffer_pool_config_set_video_alignment(null, &a2);
    _ = c.gst_buffer_pool_config_get_video_alignment(config, null);
    c.gst_structure_free(config);
    config = null;
    var p0 = c.gst_structure_new_empty("video-meta");
    a2.padding_bottom = 9;
    c.gst_buffer_pool_config_set_video_alignment(p0, &a2);
    const p1s = c.gst_structure_new_empty("video-meta");
    var a4 = std.mem.zeroes(c.GstVideoAlignment);
    a4.padding_top = 5;
    a4.stride_align = .{ 16, 0, 32, 1 };
    c.gst_buffer_pool_config_set_video_alignment(p1s, &a4);
    var agg: ?*c.GstStructure = null;
    for ([_][2]?*c.GstStructure{ .{ p0, p1s }, .{ p0, null }, .{ null, p1s }, .{ null, null } }) |pair| {
        agg = null;
        const ok = c.gst_meta_api_type_aggregate_params(c.gst_video_meta_api_get_type(), &agg, pair[0], pair[1]);
        const s = if (agg != null) c.gst_structure_to_string(agg) else null;
        out("  aggregate {d} {s}", .{ ok, str(s) });
        c.g_free(s);
        if (agg != null) c.gst_structure_free(agg);
    }
    const wrong = c.gst_structure_new_empty("other");
    agg = null;
    out("  aggregate wrong {d} {any}", .{ c.gst_meta_api_type_aggregate_params(c.gst_video_meta_api_get_type(), &agg, wrong, null), agg == null });
    c.gst_structure_free(wrong);
    c.gst_structure_free(p0);
    p0 = null;
    c.gst_structure_free(p1s);
}

fn frameTests() void {
    out("frame", .{});
    var line: [256]u8 = undefined;
    for ([_]c.GstVideoFormat{ c.GST_VIDEO_FORMAT_I420, c.GST_VIDEO_FORMAT_NV12, c.GST_VIDEO_FORMAT_RGBA, c.GST_VIDEO_FORMAT_RGB8P, c.GST_VIDEO_FORMAT_v210, c.GST_VIDEO_FORMAT_NV12_4L4, c.GST_VIDEO_FORMAT_NV12_64Z32, c.GST_VIDEO_FORMAT_UYVP, c.GST_VIDEO_FORMAT_A420_10LE }) |fmt| for ([_]c.GstVideoInterlaceMode{ 0, 1, 2 }) |im| {
        var vi: c.GstVideoInfo = undefined;
        _ = c.gst_video_info_set_interlaced_format(&vi, fmt, im, 37, 21);
        if (im == 1) vi.ABI.abi.field_order = c.GST_VIDEO_FIELD_ORDER_TOP_FIELD_FIRST;
        const buf = c.gst_buffer_new_allocate(null, vi.size, null);
        var mi: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(buf, &mi, c.GST_MAP_WRITE);
        for (0..mi.size) |i| mi.data[i] = @truncate(i * 7 + 3);
        c.gst_buffer_unmap(buf, &mi);
        buf[0].mini_object.flags |= c.GST_VIDEO_BUFFER_FLAG_INTERLACED | c.GST_VIDEO_BUFFER_FLAG_RFF;
        var f: c.GstVideoFrame = undefined;
        const ok = c.gst_video_frame_map(&f, &vi, buf, c.GST_MAP_READ);
        out("  map {d} {d} -> {d} flags {d} id {d} rc {d}", .{ fmt, im, ok, f.flags, f.id, buf[0].mini_object.refcount });
        if (ok == 0) continue;
        var n: usize = 0;
        for (0..vi.finfo[0].n_planes) |p| {
            const w = std.fmt.bufPrint(line[n..], "{d} ", .{@intFromPtr(f.data[p]) - @intFromPtr(f.map[0].data)}) catch break;
            n += w.len;
        }
        out("    planes {s}", .{line[0..n]});
        var padded = vi;
        var al = std.mem.zeroes(c.GstVideoAlignment);
        al.padding_right = 13;
        al.padding_bottom = 3;
        _ = c.gst_video_info_align(&padded, &al);
        const dbuf = c.gst_buffer_new_allocate(null, padded.size, null);
        _ = c.gst_buffer_memset(dbuf, 0, 0xee, padded.size);
        var df: c.GstVideoFrame = undefined;
        _ = c.gst_video_frame_map(&df, &padded, dbuf, c.GST_MAP_WRITE);
        out("    copy {d}", .{c.gst_video_frame_copy(&df, &f)});
        c.gst_video_frame_unmap(&df);
        _ = c.gst_buffer_map(dbuf, &mi, c.GST_MAP_READ);
        var h: u32 = 2166136261;
        for (mi.data[0..mi.size]) |b| h = (h ^ b) *% 16777619;
        c.gst_buffer_unmap(dbuf, &mi);
        out("    copied hash {x} size {d}", .{ h, padded.size });
        const sbuf = c.gst_buffer_new_allocate(null, vi.size, null);
        var sf: c.GstVideoFrame = undefined;
        _ = c.gst_video_frame_map(&sf, &vi, sbuf, c.GST_MAP_WRITE);
        for (0..vi.finfo[0].n_planes) |p| out("    plane {d} {d}", .{ p, c.gst_video_frame_copy_plane(&sf, &f, @intCast(p)) });
        _ = c.gst_video_frame_copy_plane(&sf, &f, 9);
        c.gst_video_frame_unmap(&sf);
        c.gst_buffer_unref(sbuf);
        var big_frame = f;
        big_frame.info.width = 99;
        _ = c.gst_video_frame_copy(&big_frame, &f);
        c.gst_video_frame_unmap(&f);
        c.gst_video_frame_unmap(&f);
        out("    after unmap rc {d}", .{buf[0].mini_object.refcount});
        c.gst_buffer_unref(dbuf);
        c.gst_buffer_unref(buf);
    };
    var vi: c.GstVideoInfo = undefined;
    _ = c.gst_video_info_set_format(&vi, c.GST_VIDEO_FORMAT_I420, 16, 16);
    const small = c.gst_buffer_new_allocate(null, 10, null);
    var f: c.GstVideoFrame = undefined;
    out("  small {d}", .{c.gst_video_frame_map(&f, &vi, small, c.GST_MAP_READ)});
    out("  no meta id {d}", .{c.gst_video_frame_map_id(&f, &vi, small, 1, c.GST_MAP_READ)});
    c.gst_buffer_unref(small);
    const big = c.gst_buffer_new_allocate(null, vi.size + 100, null);
    const m = c.gst_buffer_add_video_meta(big, c.GST_VIDEO_FRAME_FLAG_TFF, c.GST_VIDEO_FORMAT_I420, 16, 16);
    m[0].offset[1] += 50;
    m[0].offset[2] += 50;
    out("  meta map {d} flags {d}", .{ c.gst_video_frame_map(&f, &vi, big, c.GST_MAP_READ | c.GST_VIDEO_FRAME_MAP_FLAG_NO_REF), f.flags });
    out("    offsets {d} {d} rc {d}", .{ @intFromPtr(f.data[1]) - @intFromPtr(f.data[0]), @intFromPtr(f.data[2]) - @intFromPtr(f.data[0]), big[0].mini_object.refcount });
    c.gst_video_frame_unmap(&f);
    var wrong = vi;
    _ = c.gst_video_info_set_format(&wrong, c.GST_VIDEO_FORMAT_NV12, 16, 16);
    out("  meta mismatch {d}", .{c.gst_video_frame_map(&f, &wrong, big, c.GST_MAP_READ)});
    var wide = vi;
    wide.width = 32;
    out("  meta too wide {d}", .{c.gst_video_frame_map(&f, &wide, big, c.GST_MAP_READ)});
    out("  meta id 0 {d}", .{c.gst_video_frame_map_id(&f, &vi, big, 0, c.GST_MAP_READ)});
    c.gst_video_frame_unmap(&f);
    _ = c.gst_buffer_ref(big);
    out("  write shared {d}", .{c.gst_video_frame_map(&f, &vi, big, c.GST_MAP_WRITE)});
    c.gst_buffer_unref(big);
    c.gst_buffer_unref(big);
    _ = c.gst_video_frame_map(null, &vi, big, 0);
    _ = c.gst_video_frame_map(&f, &vi, null, 0);
    c.gst_video_frame_unmap(null);
    _ = c.gst_video_frame_copy(null, null);
    _ = c.gst_video_frame_copy_plane(null, &f, 0);
}

fn pools() void {
    out("pool", .{});
    const pool = c.gst_video_buffer_pool_new();
    out("  type {s} floating {d}", .{ str(c.g_type_name_from_instance(@ptrCast(@alignCast(pool)))), c.g_object_is_floating(pool) });
    const opts = c.gst_buffer_pool_get_options(pool);
    out("  options {s} {s} {any}", .{ str(opts[0]), str(opts[1]), opts[2] == null });
    for ([_][*c]const u8{ "video/x-raw,format=I420,width=63,height=31,framerate=30/1", "video/x-raw,format=NV12,width=64,height=48", "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12,width=64,height=48", "video/x-raw(memory:DMABuf),format=DMA_DRM,drm-format=NV12:0x0100000000000002,width=64,height=48", "audio/x-raw" }) |cs| for ([_]bool{ false, true }) |withmeta| for ([_]c.guint{ 0, 4000, 100000 }) |size| {
        const caps = c.gst_caps_from_string(cs);
        const config = c.gst_buffer_pool_get_config(pool);
        c.gst_buffer_pool_config_set_params(config, caps, size, 2, 4);
        if (withmeta) {
            c.gst_buffer_pool_config_add_option(config, "GstBufferPoolOptionVideoMeta");
            c.gst_buffer_pool_config_add_option(config, "GstBufferPoolOptionVideoAlignment");
            var al = std.mem.zeroes(c.GstVideoAlignment);
            al.padding_left = 2;
            al.padding_right = 6;
            al.padding_top = 1;
            al.stride_align = .{ 31, 15, 15, 0 };
            c.gst_buffer_pool_config_set_video_alignment(config, &al);
            var params = std.mem.zeroes(c.GstAllocationParams);
            params.@"align" = 7;
            c.gst_buffer_pool_config_set_allocator(config, null, &params);
        }
        const ok = c.gst_buffer_pool_set_config(pool, config);
        const got = c.gst_buffer_pool_get_config(pool);
        const s = c.gst_structure_to_string(got);
        out("  config {s} meta {any} size {d} -> {d} {s}", .{ str(cs), withmeta, size, ok, str(s) });
        c.g_free(s);
        c.gst_structure_free(got);
        if (ok != 0) {
            _ = c.gst_buffer_pool_set_active(pool, 1);
            var buf: [*c]c.GstBuffer = null;
            const r = c.gst_buffer_pool_acquire_buffer(pool, &buf, null);
            out("   acquire {d} size {d}", .{ r, c.gst_buffer_get_size(buf) });
            showVMeta("pool meta", c.gst_buffer_get_video_meta(buf));
            c.gst_buffer_unref(buf);
            _ = c.gst_buffer_pool_set_active(pool, 0);
        }
        c.gst_caps_unref(caps);
    };
    const config = c.gst_buffer_pool_get_config(pool);
    c.gst_buffer_pool_config_set_params(config, null, 100, 0, 0);
    out("  no caps {d}", .{c.gst_buffer_pool_set_config(pool, config)});
    c.gst_object_unref(pool);
}

fn events() void {
    out("event", .{});
    for ([_]c.gboolean{ 0, 1 }) |still| {
        const e = c.gst_video_event_new_still_frame(still);
        var v: c.gboolean = 7;
        const s = c.gst_structure_to_string(c.gst_event_get_structure(e));
        out("  still {d} {s} parse {d} {d} fku {d}", .{ still, str(s), c.gst_video_event_parse_still_frame(e, &v), v, c.gst_video_event_is_force_key_unit(e) });
        c.g_free(s);
        c.gst_event_unref(e);
    }
    for ([_]i64{ 0, 1000, -1000, -5000000000 }) |off| {
        const d = c.gst_video_event_new_downstream_force_key_unit(1000000000, 2000000000, 3000000000, 1, 5);
        c.gst_event_set_running_time_offset(d, off);
        var ts: u64 = 0;
        var stt: u64 = 0;
        var rt: u64 = 0;
        var all: c.gboolean = 0;
        var cnt: c.guint = 0;
        const s = c.gst_structure_to_string(c.gst_event_get_structure(d));
        out("  down {d} {s} parse {d} {d} {d} {d} {d} {d} is {d} up {d} still {d}", .{ off, str(s), c.gst_video_event_parse_downstream_force_key_unit(d, &ts, &stt, &rt, &all, &cnt), ts, stt, rt, all, cnt, c.gst_video_event_is_force_key_unit(d), c.gst_video_event_parse_upstream_force_key_unit(d, &rt, &all, &cnt), c.gst_video_event_parse_still_frame(d, null) });
        c.g_free(s);
        _ = c.gst_video_event_parse_downstream_force_key_unit(d, null, null, null, null, null);
        c.gst_event_unref(d);
        const u = c.gst_video_event_new_upstream_force_key_unit(c.GST_CLOCK_TIME_NONE, 0, 2);
        c.gst_event_set_running_time_offset(u, off);
        const s2 = c.gst_structure_to_string(c.gst_event_get_structure(u));
        out("  up {d} {s} parse {d} {d} {d} {d} down {d}", .{ off, str(s2), c.gst_video_event_parse_upstream_force_key_unit(u, &rt, &all, &cnt), rt, all, cnt, c.gst_video_event_parse_downstream_force_key_unit(u, &ts, &stt, &rt, &all, &cnt) });
        c.g_free(s2);
        c.gst_event_unref(u);
    }
    const partial = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("GstForceKeyUnit"));
    var ts: u64 = 0;
    var stt: u64 = 0;
    var rt: u64 = 0;
    var all: c.gboolean = 9;
    var cnt: c.guint = 9;
    out("  partial {d} {d} {d} {d} {d} {d}", .{ c.gst_video_event_parse_downstream_force_key_unit(partial, &ts, &stt, &rt, &all, &cnt), ts, stt, rt, all, cnt });
    c.gst_event_unref(partial);
    const other = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("Other"));
    out("  other {d} {d}", .{ c.gst_video_event_is_force_key_unit(other), c.gst_video_event_parse_still_frame(other, null) });
    c.gst_event_unref(other);
    const nostate = c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM, c.gst_structure_new_empty("GstEventStillFrame"));
    out("  nostate {d}", .{c.gst_video_event_parse_still_frame(nostate, null)});
    c.gst_event_unref(nostate);
    const eos = c.gst_event_new_eos();
    out("  eos {d} {d}", .{ c.gst_video_event_is_force_key_unit(eos), c.gst_video_event_parse_upstream_force_key_unit(eos, null, null, null) });
    c.gst_event_unref(eos);
    _ = c.gst_video_event_is_force_key_unit(null);
    _ = c.gst_video_event_parse_still_frame(null, null);
}

var notified: u32 = 0;

fn notify(_: c.gpointer) callconv(.c) void {
    notified += 1;
}

fn codecutils() void {
    out("codec", .{});
    const f: [*c]c.GstVideoCodecFrame = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoCodecFrame))));
    f[0].ref_count = 1;
    f[0].input_buffer = c.gst_buffer_new();
    f[0].events = c.g_list_append(null, c.gst_event_new_eos());
    c.gst_video_codec_frame_set_user_data(f, @ptrFromInt(1), notify);
    c.gst_video_codec_frame_set_user_data(f, @ptrFromInt(2), notify);
    out("  user {d} notified {d}", .{ @intFromPtr(c.gst_video_codec_frame_get_user_data(f)), notified });
    _ = c.gst_video_codec_frame_ref(f);
    out("  rc {d}", .{f[0].ref_count});
    c.gst_video_codec_frame_unref(f);
    c.gst_video_codec_frame_unref(f);
    out("  freed notified {d}", .{notified});
    const s: [*c]c.GstVideoCodecState = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoCodecState))));
    s[0].ref_count = 1;
    s[0].caps = c.gst_caps_new_empty_simple("video/x-raw");
    s[0].mastering_display_info = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstVideoMasteringDisplayInfo))));
    _ = c.gst_video_codec_state_ref(s);
    out("  state rc {d}", .{s[0].ref_count});
    c.gst_video_codec_state_unref(s);
    c.gst_video_codec_state_unref(s);
    _ = c.gst_video_codec_frame_ref(null);
    c.gst_video_codec_frame_unref(null);
    _ = c.gst_video_codec_state_ref(null);
    c.gst_video_codec_state_unref(null);
    var zero = std.mem.zeroes(c.GstVideoCodecFrame);
    c.gst_video_codec_frame_unref(&zero);
    var zs = std.mem.zeroes(c.GstVideoCodecState);
    c.gst_video_codec_state_unref(&zs);
    out("  types {s} {s}", .{ str(c.g_type_name(c.gst_video_codec_frame_get_type())), str(c.g_type_name(c.gst_video_codec_state_get_type())) });
}

pub fn main() void {
    c.gst_init(null, null);
    timecodes();
    metas();
    frameTests();
    pools();
    events();
    codecutils();
}
