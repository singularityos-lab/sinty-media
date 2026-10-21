const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = std.math.maxInt(u64);

fn t(v: u64) i64 {
    return if (v == NONE) -1 else @intCast(v);
}

fn mk(start: u8, n: usize, pts: u64, dts: u64, off: u64, discont: bool) [*c]c.GstBuffer {
    const b = if (n == 0) c.gst_buffer_new() else blk: {
        const d: [*c]u8 = @ptrCast(c.g_malloc(n));
        for (0..n) |i| d[i] = start +% @as(u8, @truncate(i));
        break :blk c.gst_buffer_new_wrapped(d, n);
    };
    b[0].pts = pts;
    b[0].dts = dts;
    b[0].offset = off;
    if (discont) b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
    return b;
}

fn state(a: ?*c.GstAdapter, label: []const u8) void {
    var pd: u64 = 0;
    var dd: u64 = 0;
    var od: u64 = 0;
    const pts = c.gst_adapter_prev_pts(a, &pd);
    const dts = c.gst_adapter_prev_dts(a, &dd);
    const off = c.gst_adapter_prev_offset(a, &od);
    out("{s}: avail={d} fast={d} pts={d}/{d} dts={d}/{d} off={d}/{d} disc pts={d} dts={d} off={d} dist={d}", .{ label, c.gst_adapter_available(a), c.gst_adapter_available_fast(a), t(pts), pd, t(dts), dd, t(off), od, t(c.gst_adapter_pts_at_discont(a)), t(c.gst_adapter_dts_at_discont(a)), t(c.gst_adapter_offset_at_discont(a)), c.gst_adapter_distance_from_discont(a) });
}

fn bytes(p: ?*const anyopaque, n: usize) void {
    if (p == null) {
        out("  null", .{});
        return;
    }
    const d: [*]const u8 = @ptrCast(p.?);
    var buf: [512]u8 = undefined;
    var k: usize = 0;
    for (0..@min(n, 200)) |i| {
        _ = std.fmt.bufPrint(buf[k..], "{x:0>2}", .{d[i]}) catch break;
        k += 2;
    }
    out("  [{s}]", .{buf[0..k]});
}

fn showBuffer(b: [*c]c.GstBuffer, label: []const u8) void {
    if (b == null) {
        out("{s}: null", .{label});
        return;
    }
    var info: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &info, c.GST_MAP_READ);
    out("{s}: size={d} mems={d} pts={d} dts={d} off={d} flags={d} metas={d}", .{ label, info.size, c.gst_buffer_n_memory(b), t(b[0].pts), t(b[0].dts), t(b[0].offset), b[0].mini_object.flags, c.gst_buffer_get_n_meta(b, c.gst_reference_timestamp_meta_api_get_type()) });
    bytes(info.data, info.size);
    c.gst_buffer_unmap(b, &info);
}

pub fn main() void {
    c.gst_init(null, null);
    const a = c.gst_adapter_new();
    out("type {s}", .{std.mem.span(c.g_type_name(c.gst_adapter_get_type()))});
    state(a, "empty");
    c.gst_adapter_push(a, mk(0, 10, 1000, 900, 50, false));
    state(a, "push1");
    c.gst_adapter_push(a, mk(10, 5, NONE, NONE, NONE, false));
    const b3 = mk(15, 20, 3000, NONE, 70, true);
    const caps = c.gst_caps_from_string("timestamp/x-test");
    _ = c.gst_buffer_add_reference_timestamp_meta(b3, caps, 42, 7);
    c.gst_caps_unref(caps);
    c.gst_adapter_push(a, b3);
    c.gst_adapter_push(a, mk(35, 0, 4000, 4000, 80, false));
    c.gst_adapter_push(a, mk(35, 15, 5000, 4500, NONE, false));
    state(a, "push5");
    var pd: u64 = 0;
    for ([_]usize{ 0, 5, 9, 10, 14, 15, 30, 40, 49 }) |o| {
        const p = c.gst_adapter_prev_pts_at_offset(a, o, &pd);
        var dd: u64 = 0;
        const d = c.gst_adapter_prev_dts_at_offset(a, o, &dd);
        out("at {d}: pts {d}/{d} dts {d}/{d}", .{ o, t(p), pd, t(d), dd });
    }
    bytes(c.gst_adapter_map(a, 4), 4);
    c.gst_adapter_unmap(a);
    bytes(c.gst_adapter_map(a, 12), 12);
    out("fast after assemble {d}", .{c.gst_adapter_available_fast(a)});
    bytes(c.gst_adapter_map(a, 30), 30);
    out("map too big null {d}", .{@intFromBool(c.gst_adapter_map(a, 100) == null)});
    var copy: [16]u8 = undefined;
    c.gst_adapter_copy(a, &copy, 8, 16);
    bytes(&copy, 16);
    const gb = c.gst_adapter_copy_bytes(a, 33, 5);
    var gsz: usize = 0;
    bytes(c.g_bytes_get_data(gb, &gsz), gsz);
    c.g_bytes_unref(gb);
    c.gst_adapter_flush(a, 3);
    state(a, "flush3");
    const tk = c.gst_adapter_take(a, 9);
    bytes(tk, 9);
    c.g_free(tk);
    state(a, "take9");
    showBuffer(c.gst_adapter_get_buffer(a, 3), "get head region");
    showBuffer(c.gst_adapter_get_buffer_fast(a, 10), "get fast spanning");
    showBuffer(c.gst_adapter_take_buffer(a, 3), "take head");
    state(a, "after take head");
    showBuffer(c.gst_adapter_take_buffer(a, 20), "take exact");
    state(a, "after exact");
    c.gst_adapter_push(a, mk(100, 8, 6000, NONE, NONE, false));
    showBuffer(c.gst_adapter_take_buffer(a, 18), "take merged");
    state(a, "after merged");
    showBuffer(c.gst_adapter_take_buffer_fast(a, 4), "take fast");
    state(a, "after take fast");

    c.gst_adapter_clear(a);
    state(a, "clear");
    for (0..6) |i| c.gst_adapter_push(a, mk(@intCast(i * 7), 7, NONE, NONE, NONE, false));
    const gl = c.gst_adapter_get_list(a, 20);
    out("get list len {d}", .{c.g_list_length(gl)});
    var l = gl;
    while (l != null) : (l = l.*.next) showBuffer(@ptrCast(@alignCast(l.*.data)), " item");
    c.g_list_free_full(gl, @ptrCast(&c.gst_mini_object_unref));
    c.gst_adapter_flush(a, 2);
    const gbl = c.gst_adapter_get_buffer_list(a, 12);
    out("get blist len {d}", .{c.gst_buffer_list_length(gbl)});
    for (0..c.gst_buffer_list_length(gbl)) |i| showBuffer(c.gst_buffer_list_get(gbl, @intCast(i)), " bitem");
    c.gst_buffer_list_unref(gbl);
    const tl = c.gst_adapter_take_list(a, 13);
    out("take list len {d}", .{c.g_list_length(tl)});
    c.g_list_free_full(tl, @ptrCast(&c.gst_mini_object_unref));
    state(a, "after take list");
    const tbl = c.gst_adapter_take_buffer_list(a, 9);
    out("take blist len {d}", .{c.gst_buffer_list_length(tbl)});
    c.gst_buffer_list_unref(tbl);
    state(a, "after take blist");
    out("take blist too big {d}", .{@intFromBool(c.gst_adapter_take_buffer_list(a, 100) == null)});

    c.gst_adapter_clear(a);
    const s1 = [_]u8{ 0x00, 0x00, 0x01, 0xb3, 0x11, 0x00 };
    const s2 = [_]u8{ 0x00, 0x01, 0xb8, 0x22 };
    const s3 = [_]u8{ 0x47, 0x00, 0x00, 0x00, 0x01, 0xe0, 0x00 };
    for ([_][]const u8{ &s1, &s2, &s3 }) |s| {
        const d: [*c]u8 = @ptrCast(c.g_memdup2(s.ptr, s.len));
        c.gst_adapter_push(a, c.gst_buffer_new_wrapped(d, s.len));
    }
    var val: u32 = 0;
    const total = c.gst_adapter_available(a);
    var off: usize = 0;
    while (off + 4 <= total) : (off += 1) {
        const r = c.gst_adapter_masked_scan_uint32_peek(a, 0xffffff00, 0x00000100, off, total - off, &val);
        out("scan from {d}: {d} val {x}", .{ off, r, val });
    }
    out("scan exact {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xffffffff, 0x000001b8, 0, total)});
    out("scan none {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xffffffff, 0x12345678, 0, total)});
    out("scan short {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xffffffff, 0x000001b8, 0, 3)});
    c.gst_adapter_flush(a, 7);
    out("scan after flush {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xffffff00, 0x00000100, 0, c.gst_adapter_available(a))});
    out("crit {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xff, 1, 0, 0)});
    out("crit {d}", .{c.gst_adapter_masked_scan_uint32(a, 0xff, 1, 0, 1000)});
    out("crit {d}", .{c.gst_adapter_masked_scan_uint32(a, 0x0f, 0xff, 0, 4)});

    out("crit avail {d}", .{c.gst_adapter_available(null)});
    c.gst_adapter_push(a, null);
    c.gst_adapter_flush(a, 1000);
    out("crit take {d} {d}", .{ @intFromBool(c.gst_adapter_take(a, 0) == null), @intFromBool(c.gst_adapter_map(null, 1) == null) });
    c.gst_adapter_copy(a, &copy, 0, 0);
    c.gst_adapter_copy(a, &copy, 100, 1);
    out("crit list {d}", .{@intFromBool(c.gst_adapter_take_list(a, 1000) == null)});
    out("crit pts {d}", .{t(c.gst_adapter_prev_pts(null, null))});
    c.g_object_unref(a);
    out("done", .{});
}
