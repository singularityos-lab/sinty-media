const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

fn changed(p: ?*c.GstPromise, data: c.gpointer) callconv(.c) void {
    _ = p;
    out("  change func {s}", .{str(@ptrCast(data))});
}

fn notify(data: c.gpointer) callconv(.c) void {
    out("  notify {s}", .{str(@ptrCast(data))});
}

fn setterType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) {
        S.t = c.g_type_register_static_simple(c.gst_element_get_type(), "ExtrasSetter", @sizeOf(c.GstElementClass), null, @sizeOf(c.GstElement), null, 0);
        const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
        c.g_type_add_interface_static(S.t, c.gst_tag_setter_get_type(), &info);
        c.g_type_add_interface_static(S.t, c.gst_toc_setter_get_type(), &info);
    }
    return S.t;
}

fn tags(l: ?*const c.GstTagList) void {
    if (l == null) {
        out("  tags (null)", .{});
        return;
    }
    const s = c.gst_tag_list_to_string(l);
    out("  tags {s}", .{str(s)});
    c.g_free(s);
}

pub fn main() void {
    c.gst_init(null, null);
    const q = c.gst_atomic_queue_new(2);
    var vals: [40]usize = undefined;
    for (&vals, 0..) |*v, i| v.* = i;
    for (&vals) |*v| c.gst_atomic_queue_push(q, v);
    out("queue len {d} peek {d}", .{ c.gst_atomic_queue_length(q), @as(*usize, @ptrCast(@alignCast(c.gst_atomic_queue_peek(q)))).* });
    var sum: usize = 0;
    var n: usize = 0;
    while (c.gst_atomic_queue_pop(q)) |p| {
        sum += @as(*usize, @ptrCast(@alignCast(p))).*;
        n += 1;
        if (n == 10) {
            c.gst_atomic_queue_push(q, &vals[0]);
        }
    }
    out("popped {d} sum {d} len {d} peek null {d}", .{ n, sum, c.gst_atomic_queue_length(q), @intFromBool(c.gst_atomic_queue_peek(q) == null) });
    c.gst_atomic_queue_ref(q);
    c.gst_atomic_queue_unref(q);
    c.gst_atomic_queue_unref(q);
    out("queue type {s}", .{str(c.g_type_name(c.gst_atomic_queue_get_type()))});

    const p = c.gst_promise_new_with_change_func(changed, @constCast("p1"), notify);
    out("promise type {s}", .{str(c.g_type_name(c.gst_promise_get_type()))});
    c.gst_promise_reply(p, c.gst_structure_new("answer", "x", c.G_TYPE_INT, @as(c_int, 42), @as([*c]const u8, null)));
    out("wait {d}", .{c.gst_promise_wait(p)});
    const r = c.gst_promise_get_reply(p);
    out("reply {s} x={d}", .{ str(c.gst_structure_get_name(r)), blk: {
        var x: c_int = 0;
        _ = c.gst_structure_get_int(r, "x", &x);
        break :blk x;
    } });
    c.gst_promise_reply(p, null);
    c.gst_promise_interrupt(p);
    c.gst_promise_expire(p);
    c.gst_promise_unref(p);
    const p2 = c.gst_promise_new();
    out("reply before {d}", .{@intFromBool(c.gst_promise_get_reply(p2) == null)});
    c.gst_promise_interrupt(p2);
    out("interrupted {d}", .{c.gst_promise_wait(p2)});
    c.gst_promise_reply(p2, c.gst_structure_new_empty("late"));
    out("after late reply {d}", .{c.gst_promise_wait(p2)});
    c.gst_promise_expire(p2);
    c.gst_promise_unref(p2);
    var p3: ?*c.GstPromise = c.gst_promise_new();
    c.gst_promise_expire(p3);
    out("expired {d}", .{c.gst_promise_wait(p3)});
    c.gst_promise_interrupt(p3);
    c.gst_clear_promise(&p3);
    out("cleared {d}", .{@intFromBool(p3 == null)});

    const f = c.gst_param_spec_fraction("rate", "Rate", "r", 1, 1, 60, 1, 30, 1, c.G_PARAM_READWRITE);
    out("fraction {s} type {s}", .{ str(c.g_param_spec_get_name(f)), str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(f))) });
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_fraction_get_type());
    c.g_param_value_set_default(f, &v);
    out("default {d}/{d}", .{ c.gst_value_get_fraction_numerator(&v), c.gst_value_get_fraction_denominator(&v) });
    c.gst_value_set_fraction(&v, 90, 1);
    out("validate 90 {d}", .{c.g_param_value_validate(f, &v)});
    c.gst_value_set_fraction(&v, 15, 1);
    out("validate 15 {d}", .{c.g_param_value_validate(f, &v)});
    var v2 = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v2, c.gst_fraction_get_type());
    c.gst_value_set_fraction(&v2, 30, 2);
    out("cmp {d}", .{c.g_param_values_cmp(f, &v, &v2)});
    c.g_value_unset(&v);
    c.g_value_unset(&v2);
    out("bad fraction null {d}", .{@intFromBool(c.gst_param_spec_fraction("bad", "B", "b", 1, 1, 2, 1, 5, 1, c.G_PARAM_READWRITE) == null)});
    const a = c.gst_param_spec_array("list", "List", "l", c.g_param_spec_int("item", "I", "i", 0, 10, 5, c.G_PARAM_READWRITE), c.G_PARAM_READWRITE);
    out("array {s} type {s}", .{ str(c.g_param_spec_get_name(a)), str(c.g_type_name(c.G_TYPE_FROM_INSTANCE(a))) });
    var av = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&av, c.gst_value_array_get_type());
    var e = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&e, c.G_TYPE_INT);
    c.g_value_set_int(&e, 50);
    c.gst_value_array_append_value(&av, &e);
    c.g_value_unset(&e);
    _ = c.g_value_init(&e, c.G_TYPE_STRING);
    c.g_value_set_string(&e, "x");
    c.gst_value_array_append_value(&av, &e);
    c.g_value_unset(&e);
    out("array validate {d}", .{c.g_param_value_validate(a, &av)});
    const s = c.gst_value_serialize(&av);
    out("array after {s}", .{str(s)});
    c.g_free(s);
    var bv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bv, c.gst_value_array_get_type());
    out("array cmp {d} {d}", .{ c.g_param_values_cmp(a, &av, &bv), c.g_param_values_cmp(a, &bv, &bv) });
    c.g_value_unset(&av);
    c.g_value_unset(&bv);
    c.g_param_spec_sink(f);
    c.g_param_spec_unref(f);
    c.g_param_spec_sink(a);
    c.g_param_spec_unref(a);

    const el: ?*c.GstElement = @ptrCast(@alignCast(c.g_object_new(setterType(), @as([*c]const u8, null))));
    const ts: ?*c.GstTagSetter = @ptrCast(el);
    out("tag setter mode {d}", .{c.gst_tag_setter_get_tag_merge_mode(ts)});
    tags(c.gst_tag_setter_get_tag_list(ts));
    c.gst_tag_setter_add_tags(ts, c.GST_TAG_MERGE_APPEND, c.GST_TAG_TITLE, "one", c.GST_TAG_ARTIST, "me", @as([*c]const u8, null));
    tags(c.gst_tag_setter_get_tag_list(ts));
    var tv = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&tv, c.G_TYPE_STRING);
    c.g_value_set_string(&tv, "two");
    c.gst_tag_setter_add_tag_value(ts, c.GST_TAG_MERGE_APPEND, c.GST_TAG_TITLE, &tv);
    c.gst_tag_setter_add_tag_values(ts, c.GST_TAG_MERGE_REPLACE, c.GST_TAG_ARTIST, &tv, @as([*c]const u8, null));
    c.g_value_unset(&tv);
    tags(c.gst_tag_setter_get_tag_list(ts));
    const other = c.gst_tag_list_new(c.GST_TAG_ALBUM, "alb", @as([*c]const u8, null));
    c.gst_tag_setter_merge_tags(ts, other, c.GST_TAG_MERGE_KEEP);
    tags(c.gst_tag_setter_get_tag_list(ts));
    c.gst_tag_setter_set_tag_merge_mode(ts, c.GST_TAG_MERGE_REPLACE_ALL);
    out("mode {d}", .{c.gst_tag_setter_get_tag_merge_mode(ts)});
    c.gst_tag_setter_reset_tags(ts);
    tags(c.gst_tag_setter_get_tag_list(ts));
    c.gst_tag_setter_merge_tags(ts, other, c.GST_TAG_MERGE_KEEP_ALL);
    tags(c.gst_tag_setter_get_tag_list(ts));
    c.gst_tag_setter_merge_tags(ts, other, c.GST_TAG_MERGE_KEEP);
    tags(c.gst_tag_setter_get_tag_list(ts));
    c.gst_tag_setter_set_tag_merge_mode(ts, c.GST_TAG_MERGE_UNDEFINED);
    c.gst_tag_list_unref(other);
    const tc: ?*c.GstTocSetter = @ptrCast(el);
    out("toc null {d}", .{@intFromBool(c.gst_toc_setter_get_toc(tc) == null)});
    const toc = c.gst_toc_new(c.GST_TOC_SCOPE_GLOBAL);
    c.gst_toc_setter_set_toc(tc, toc);
    const got = c.gst_toc_setter_get_toc(tc);
    out("toc same {d} scope {d}", .{ @intFromBool(got == toc), c.gst_toc_get_scope(got) });
    c.gst_mini_object_unref(@ptrCast(@alignCast(got)));
    c.gst_mini_object_unref(@ptrCast(@alignCast(toc)));
    c.gst_toc_setter_reset(tc);
    out("toc reset null {d}", .{@intFromBool(c.gst_toc_setter_get_toc(tc) == null)});
    c.gst_toc_setter_set_toc(@ptrCast(c.gst_bin_new("x")), null);
    _ = c.gst_object_ref_sink(el);
    c.gst_object_unref(el);
    out("setter types {s} {s}", .{ str(c.g_type_name(c.gst_tag_setter_get_type())), str(c.g_type_name(c.gst_toc_setter_get_type())) });

    const b = c.gst_buffer_new();
    const pm = c.gst_buffer_add_protection_meta(b, c.gst_structure_new("application/x-cenc", "iv_size", c.G_TYPE_UINT, @as(c_uint, 8), @as([*c]const u8, null)));
    out("protection {s} api {s} info {s}", .{ str(c.gst_structure_get_name(pm.*.info)), str(c.g_type_name(c.gst_protection_meta_api_get_type())), str(c.g_type_name(c.gst_protection_meta_get_info().*.type)) });
    const b2 = c.gst_buffer_copy(b);
    const m2: ?*c.GstProtectionMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b2, c.gst_protection_meta_api_get_type())));
    out("copied meta {s}", .{if (m2 != null) str(c.gst_structure_get_name(m2.?.info)) else "(none)"});
    c.gst_buffer_unref(b2);
    c.gst_buffer_unref(b);
    var ids = [_][*c]const u8{ "69f908af-4816-46ea-910c-cd5dcccb0a3a", null };
    out("select {s} filter null {d}", .{ str(c.gst_protection_select_system(@ptrCast(&ids))), @intFromBool(c.gst_protection_filter_systems_by_available_decryptors(@ptrCast(&ids)) == null) });
    out("done", .{});
}
