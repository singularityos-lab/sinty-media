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

fn z(p: [*:0]const u8) [*c]const u8 {
    return p;
}

const end: ?*anyopaque = null;

fn onNotify(o: ?*c.GObject, pspec: [*c]c.GParamSpec, _: c.gpointer) callconv(.c) void {
    out("  notify {s} on {s}", .{ str(pspec.*.name), str(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class.*.g_type)) });
}

fn onStreamNotify(_: ?*c.GstStreamCollection, s: ?*c.GstStream, pspec: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    out("  stream-notify[{s}] {s} {s}", .{ str(@ptrCast(data)), str(c.gst_stream_get_stream_id(s)), str(pspec.*.name) });
}

fn dumpStream(s: ?*c.GstStream) void {
    const cp = c.gst_stream_get_caps(s);
    const tg = c.gst_stream_get_tags(s);
    const cs = if (cp != null) c.gst_caps_to_string(cp) else null;
    const ts = if (tg != null) c.gst_tag_list_to_string(tg) else null;
    out("stream {s} name {s} type {d} {s} flags {d} caps {s} tags {s}", .{ str(c.gst_stream_get_stream_id(s)), str(c.gst_object_get_name(@ptrCast(s))), c.gst_stream_get_stream_type(s), str(c.gst_stream_type_get_name(c.gst_stream_get_stream_type(s))), c.gst_stream_get_stream_flags(s), str(cs), str(ts) });
    c.g_free(cs);
    c.g_free(ts);
    if (cp != null) c.gst_caps_unref(cp);
    if (tg != null) c.gst_tag_list_unref(tg);
}

pub fn main() void {
    c.gst_init(null, null);
    out("types {s} {s}", .{ str(c.g_type_name(c.gst_stream_get_type())), str(c.g_type_name(c.gst_stream_collection_get_type())) });
    var t: c_uint = 1;
    while (t < 40) : (t += 1) out("type name {d} {s}", .{ t, str(c.gst_stream_type_get_name(t)) });
    const cat = c._gst_debug_get_category("streams");
    out("cat {s} {s}", .{ str(c.gst_debug_category_get_name(cat)), str(c.gst_debug_category_get_description(cat)) });
    const cat2 = c._gst_debug_get_category("streamcollection");
    out("cat {s} {s}", .{ str(c.gst_debug_category_get_name(cat2)), str(c.gst_debug_category_get_description(cat2)) });

    const caps = c.gst_caps_from_string("audio/x-raw, rate=(int)48000");
    const a = c.gst_stream_new("audio-1", caps, c.GST_STREAM_TYPE_AUDIO, c.GST_STREAM_FLAG_SELECT);
    const v = c.gst_stream_new("video-1", null, c.GST_STREAM_TYPE_VIDEO, c.GST_STREAM_FLAG_NONE);
    const r = c.gst_stream_new(null, null, c.GST_STREAM_TYPE_TEXT, c.GST_STREAM_FLAG_SPARSE);
    out("random id len {d} name matches {d} floating {d}", .{ std.mem.len(c.gst_stream_get_stream_id(r)), @intFromBool(std.mem.eql(u8, str(c.gst_stream_get_stream_id(r)), str(@as(*c.GstObject, @ptrCast(@alignCast(r))).name))), c.g_object_is_floating(r) });
    dumpStream(a);
    dumpStream(v);
    _ = c.g_signal_connect_data(a, "notify", @ptrCast(&onNotify), null, null, 0);

    const col = c.gst_stream_collection_new("upstream");
    const col2 = c.gst_stream_collection_new(null);
    out("collection {s} name {s} / {s} name {s} size {d}", .{ str(c.gst_stream_collection_get_upstream_id(col)), str(c.gst_object_get_name(@ptrCast(col))), str(c.gst_stream_collection_get_upstream_id(col2)), str(c.gst_object_get_name(@ptrCast(col2))), c.gst_stream_collection_get_size(col) });
    _ = c.g_signal_connect_data(col, "stream-notify", @ptrCast(&onStreamNotify), @constCast("all"), null, 0);
    _ = c.g_signal_connect_data(col, "stream-notify::caps", @ptrCast(&onStreamNotify), @constCast("caps"), null, 0);
    out("add {d} {d} {d}", .{ c.gst_stream_collection_add_stream(col, @ptrCast(@alignCast(c.gst_object_ref(a)))), c.gst_stream_collection_add_stream(col, @ptrCast(@alignCast(c.gst_object_ref(v)))), c.gst_stream_collection_add_stream(col, null) });
    out("size {d} first {s} second {s}", .{ c.gst_stream_collection_get_size(col), str(c.gst_stream_get_stream_id(c.gst_stream_collection_get_stream(col, 0))), str(c.gst_stream_get_stream_id(c.gst_stream_collection_get_stream(col, 1))) });

    out("set flags", .{});
    c.gst_stream_set_stream_flags(a, c.GST_STREAM_FLAG_UNSELECT);
    out("set type", .{});
    c.gst_stream_set_stream_type(a, c.GST_STREAM_TYPE_AUDIO);
    out("set same caps", .{});
    c.gst_stream_set_caps(a, caps);
    out("set other caps", .{});
    const caps2 = c.gst_caps_from_string("audio/x-raw, rate=(int)44100");
    c.gst_stream_set_caps(a, caps2);
    out("set null caps", .{});
    c.gst_stream_set_caps(a, null);
    out("set tags", .{});
    const tags = c.gst_tag_list_new(z("language-code"), z("en"), end);
    c.gst_stream_set_tags(a, tags);
    out("set same tags", .{});
    c.gst_stream_set_tags(a, tags);
    out("set null tags", .{});
    c.gst_stream_set_tags(a, null);
    c.gst_stream_set_tags(a, tags);
    out("set video caps", .{});
    c.gst_stream_set_caps(v, caps);
    out("g_object_set", .{});
    c.g_object_set(a, "stream-flags", @as(c_uint, c.GST_STREAM_FLAG_SELECT), end);
    dumpStream(a);
    dumpStream(v);

    var id: [*c]u8 = null;
    var fl: c_uint = 0;
    var ty: c_uint = 0;
    var gc: ?*c.GstCaps = null;
    var gt: ?*c.GstTagList = null;
    c.g_object_get(a, "stream-id", &id, "stream-flags", &fl, "stream-type", &ty, "caps", &gc, "tags", &gt, end);
    out("get {s} {d} {d} caps {d} tags {d}", .{ str(id), fl, ty, @intFromBool(gc != null), @intFromBool(gt != null) });
    c.g_free(id);
    if (gt) |g| c.gst_tag_list_unref(g);
    var up: [*c]u8 = null;
    c.g_object_get(col, "upstream-id", &up, end);
    out("upstream prop {s}", .{str(up)});
    c.g_free(up);

    out("bad calls", .{});
    out("{d}", .{c.gst_stream_get_stream_type(null)});
    c.gst_stream_set_caps(null, null);
    out("{d}", .{c.gst_stream_collection_get_size(null)});

    const pspec = c.g_object_class_find_property(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(a))).g_class)), "stream-type");
    out("pspec {s} {s} {s} flags {d}", .{ str(c.g_param_spec_get_nick(pspec)), str(c.g_param_spec_get_blurb(pspec)), str(c.g_type_name(pspec.*.value_type)), pspec.*.flags });
    var n: c_uint = 0;
    const ids = c.g_signal_list_ids(c.gst_stream_collection_get_type(), &n);
    var qi: c_uint = 0;
    while (qi < n) : (qi += 1) {
        var q: c.GSignalQuery = undefined;
        c.g_signal_query(ids[qi], &q);
        out("signal {s} flags {d} params {d} ret {s}", .{ str(q.signal_name), q.signal_flags, q.n_params, str(c.g_type_name(q.return_type)) });
    }
    c.g_free(ids);
    c.gst_object_unref(col);
    c.gst_object_unref(col2);
    out("after collection: a refs {d}", .{@as(*c.GObject, @ptrCast(@alignCast(a))).ref_count});
    c.gst_stream_set_stream_flags(a, c.GST_STREAM_FLAG_NONE);
    c.gst_object_unref(a);
    c.gst_object_unref(v);
    c.gst_object_unref(r);
    if (gc) |g| c.gst_caps_unref(g);
    c.gst_caps_unref(caps);
    c.gst_caps_unref(caps2);
    c.gst_tag_list_unref(tags);
}
