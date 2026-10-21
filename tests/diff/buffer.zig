const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const all = std.math.maxInt(c.gsize);

fn mini(p: anytype) [*c]c.GstMiniObject {
    return @ptrCast(@alignCast(p));
}

fn unref(b: [*c]c.GstBuffer) void {
    c.gst_mini_object_unref(mini(b));
}

fn dump(label: []const u8, b: [*c]c.GstBuffer) void {
    var data: [64]u8 = undefined;
    const size = c.gst_buffer_get_size(b);
    const n = c.gst_buffer_extract(b, 0, &data, @min(size, data.len));
    out("{s}: size {d} n_memory {d} data {s}", .{ label, size, c.gst_buffer_n_memory(b), data[0..n] });
}

fn wrapped(text: []const u8) [*c]c.GstMemory {
    const p = c.g_memdup2(text.ptr, text.len);
    return c.gst_memory_new_wrapped(0, p, text.len, 0, text.len, p, c.g_free);
}

var freed_wrapped: u32 = 0;
fn notifyFree(_: c.gpointer) callconv(.c) void {
    freed_wrapped += 1;
}

fn countMeta(_: [*c]c.GstBuffer, _: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const n: *u32 = @ptrCast(@alignCast(data));
    n.* += 1;
    return 1;
}

fn listItem(buf: [*c][*c]c.GstBuffer, idx: c.guint, _: c.gpointer) callconv(.c) c.gboolean {
    out("list item {d} size {d}", .{ idx, c.gst_buffer_get_size(buf.*) });
    return 1;
}

pub fn main() void {
    c.gst_init(null, null);

    const a = c.gst_buffer_new_allocate(null, 8, null);
    out("allocate size {d} n_memory {d} writable {d}", .{ c.gst_buffer_get_size(a), c.gst_buffer_n_memory(a), c.gst_mini_object_is_writable(mini(a)) });
    _ = c.gst_buffer_memset(a, 0, 'x', 8);
    out("fill {d}", .{c.gst_buffer_fill(a, 2, "abcd", 4)});
    dump("a", a);
    out("memcmp {d} {d}", .{ c.gst_buffer_memcmp(a, 2, "abcd", 4), @intFromBool(c.gst_buffer_memcmp(a, 2, "abce", 4) != 0) });

    const s = "hello-world";
    const w = c.gst_buffer_new_wrapped_full(c.GST_MEMORY_FLAG_READONLY, @constCast(s), s.len, 0, s.len, null, notifyFree);
    dump("wrapped", w);
    out("wrapped readonly fill {d}", .{c.gst_buffer_fill(w, 0, "H", 1)});
    dump("after fill", w);

    const b = c.gst_buffer_new();
    c.gst_buffer_append_memory(b, wrapped("one "));
    c.gst_buffer_append_memory(b, wrapped("two "));
    c.gst_buffer_prepend_memory(b, wrapped("zero "));
    c.gst_buffer_insert_memory(b, 2, wrapped("half "));
    dump("b", b);
    var idx: c.guint = 0;
    var len: c.guint = 0;
    var skip: c.gsize = 0;
    out("find {d} idx {d} len {d} skip {d}", .{ c.gst_buffer_find_memory(b, 7, 6, &idx, &len, &skip), idx, len, skip });
    var offset: c.gsize = 0;
    var maxsize: c.gsize = 0;
    out("sizes range {d} offset {d} maxsize {d}", .{ c.gst_buffer_get_sizes_range(b, 1, 2, &offset, &maxsize), offset, maxsize });

    var info: c.GstMapInfo = undefined;
    out("map range {d}", .{c.gst_buffer_map_range(b, 1, 2, &info, c.GST_MAP_READ)});
    out("mapped {s}", .{@as([*]u8, @ptrCast(info.data))[0..info.size]});
    c.gst_buffer_unmap(b, &info);
    dump("after merge map", b);

    c.gst_buffer_resize(b, 2, 10);
    dump("resized", b);
    c.gst_buffer_set_size(b, 5);
    dump("set size", b);

    const r = c.gst_buffer_copy_region(w, c.GST_BUFFER_COPY_ALL, 6, 5);
    dump("region", r);
    const d = c.gst_buffer_copy_deep(b);
    dump("deep", d);
    out("deep shares memory {d}", .{@intFromBool(c.gst_buffer_peek_memory(d, 0) == c.gst_buffer_peek_memory(b, 0))});

    const joined = c.gst_buffer_append(c.gst_buffer_copy_region(a, c.GST_BUFFER_COPY_ALL, 0, all), c.gst_buffer_copy_region(r, c.GST_BUFFER_COPY_ALL, 0, all));
    dump("append", joined);
    const many = c.gst_buffer_new();
    var k: u8 = 0;
    while (k < 20) : (k += 1) c.gst_buffer_append_memory(many, wrapped(&[_]u8{'a' + k}));
    dump("many", many);

    a.*.pts = 1000;
    a.*.dts = 900;
    a.*.duration = 40;
    a.*.offset = 7;
    c.gst_mini_object_set_qdata(mini(a), c.g_quark_from_static_string("q"), @ptrFromInt(1), null);
    const cp = c.gst_buffer_copy_region(a, c.GST_BUFFER_COPY_TIMESTAMPS | c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_MEMORY, 0, all);
    out("copy timestamps pts {d} dts {d} duration {d} offset {d}", .{ cp.*.pts, cp.*.dts, cp.*.duration, cp.*.offset });

    out("flags set {d} has {d}", .{ c.gst_buffer_set_flags(a, c.GST_BUFFER_FLAG_DISCONT | c.GST_BUFFER_FLAG_DELTA_UNIT), c.gst_buffer_has_flags(a, c.GST_BUFFER_FLAG_DISCONT) });
    out("flags unset {d} has {d}", .{ c.gst_buffer_unset_flags(a, c.GST_BUFFER_FLAG_DISCONT), c.gst_buffer_has_flags(a, c.GST_BUFFER_FLAG_DISCONT) });
    out("flags now {d}", .{c.gst_buffer_get_flags(a) & (c.GST_BUFFER_FLAG_DISCONT | c.GST_BUFFER_FLAG_DELTA_UNIT)});

    const pm = c.gst_buffer_add_parent_buffer_meta(cp, w);
    out("parent meta {d} buffer {d}", .{ @intFromBool(pm != null), @intFromBool(pm.*.buffer == w) });
    out("meta count {d}", .{c.gst_buffer_get_n_meta(cp, c.gst_parent_buffer_meta_api_get_type())});
    var metas: u32 = 0;
    _ = c.gst_buffer_foreach_meta(cp, countMeta, &metas);
    out("foreach metas {d}", .{metas});
    const got = c.gst_buffer_get_meta(cp, c.gst_parent_buffer_meta_api_get_type());
    out("get meta {d}", .{@intFromBool(got == @as([*c]c.GstMeta, @ptrCast(pm)))});
    const cpm = c.gst_buffer_copy_region(cp, c.GST_BUFFER_COPY_META, 0, all);
    out("copied meta count {d}", .{c.gst_buffer_get_n_meta(cpm, c.gst_parent_buffer_meta_api_get_type())});
    out("remove meta {d} count {d}", .{ c.gst_buffer_remove_meta(cp, @ptrCast(pm)), c.gst_buffer_get_n_meta(cp, c.gst_parent_buffer_meta_api_get_type()) });

    const tags = [_][*c]const u8{ "memory", null };
    const api = c.gst_meta_api_type_register("TestMetaAPI", @constCast(@ptrCast(&tags)));
    out("api tags {d} {d}", .{ c.gst_meta_api_type_has_tag(api, c.g_quark_from_static_string("memory")), c.gst_meta_api_type_has_tag(api, c.g_quark_from_static_string("video")) });
    const valid = [_][*c]const u8{ "memory", "video", null };
    out("tags contain only {d}", .{c.gst_meta_api_type_tags_contain_only(api, @constCast(@ptrCast(&valid)))});

    const l = c.gst_buffer_list_new();
    c.gst_buffer_list_insert(l, -1, c.gst_buffer_copy_region(a, c.GST_BUFFER_COPY_ALL, 0, all));
    c.gst_buffer_list_insert(l, 0, c.gst_buffer_copy_region(r, c.GST_BUFFER_COPY_ALL, 0, all));
    c.gst_buffer_list_insert(l, -1, c.gst_buffer_copy_region(d, c.GST_BUFFER_COPY_ALL, 0, all));
    out("list length {d} size {d}", .{ c.gst_buffer_list_length(l), c.gst_buffer_list_calculate_size(l) });
    _ = c.gst_buffer_list_foreach(l, listItem, null);
    c.gst_buffer_list_remove(l, 1, 1);
    out("list after remove {d} first {d}", .{ c.gst_buffer_list_length(l), c.gst_buffer_get_size(c.gst_buffer_list_get(l, 0)) });
    const ld = c.gst_buffer_list_copy_deep(l);
    out("deep list {d} {d}", .{ c.gst_buffer_list_length(ld), c.gst_buffer_list_calculate_size(ld) });
    c.gst_mini_object_unref(mini(ld));
    c.gst_mini_object_unref(mini(l));

    const mem = c.gst_allocator_alloc(null, 16, null);
    var msize: c.gsize = 0;
    var moff: c.gsize = 0;
    msize = c.gst_memory_get_sizes(mem, &moff, null);
    out("memory size {d} offset {d}", .{ msize, moff });
    c.gst_memory_resize(mem, 4, 8);
    msize = c.gst_memory_get_sizes(mem, &moff, null);
    out("memory resized {d} offset {d}", .{ msize, moff });
    const share = c.gst_memory_share(mem, 2, 4);
    out("share size {d} parent {d} span {d}", .{ share.*.size, @intFromBool(share.*.parent == mem), c.gst_memory_is_span(mem, share, &moff) });
    out("is type {d}", .{c.gst_memory_is_type(mem, "SystemMemory")});
    out("default allocator {s}", .{c.gst_allocator_find(null).*.mem_type});
    c.gst_mini_object_unref(mini(share));
    c.gst_mini_object_unref(mini(mem));

    for ([_][*c]c.GstBuffer{ a, w, b, r, d, joined, many, cp, cpm }) |x| unref(x);
    out("wrapped freed {d}", .{freed_wrapped});
}
