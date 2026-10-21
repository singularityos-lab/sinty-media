const std = @import("std");
const c = @import("c").c;

const Thing = extern struct { parent: c.GstObject };
const ThingClass = extern struct { parent: c.GstObjectClass };

fn thingType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_object_get_type(), "TestThing", @sizeOf(ThingClass), null, @sizeOf(Thing), null, 0);
    return S.t;
}

fn newThing(name: ?[*:0]const u8) *c.GstObject {
    const o: *c.GstObject = @ptrCast(@alignCast(c.g_object_new(thingType(), "name", name, @as(?*anyopaque, null))));
    return o;
}

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

var freed: u32 = 0;
fn freeMini(m: [*c]c.GstMiniObject) callconv(.c) void {
    freed += 1;
    c.g_free(m);
}
fn weakNotify(data: c.gpointer, _: [*c]c.GstMiniObject) callconv(.c) void {
    out("weak notify {d}", .{@intFromPtr(data)});
}

pub fn main() void {
    c.gst_init(null, null);
    out("initialized {d}", .{c.gst_is_initialized()});

    const a = newThing(null);
    const b = newThing(null);
    const n = newThing("named");
    out("names {s} {s} {s}", .{ c.gst_object_get_name(a), c.gst_object_get_name(b), c.gst_object_get_name(n) });
    out("floating {d}", .{c.g_object_is_floating(a)});
    out("set parent {d}", .{c.gst_object_set_parent(b, a)});
    out("set parent again {d}", .{c.gst_object_set_parent(b, n)});
    out("floating after parent {d}", .{c.g_object_is_floating(b)});
    out("rename child {d}", .{c.gst_object_set_name(b, "other")});
    out("path {s}", .{c.gst_object_get_path_string(b)});
    out("ancestor {d} {d}", .{ c.gst_object_has_as_ancestor(b, a), c.gst_object_has_as_ancestor(a, b) });
    out("has parent {d}", .{c.gst_object_has_as_parent(b, a)});
    const p = c.gst_object_get_parent(b);
    out("parent is a {d}", .{@intFromBool(p == a)});
    c.gst_object_unref(p);
    _ = c.gst_object_ref(b);
    c.gst_object_unparent(b);
    out("after unparent {d}", .{@intFromBool(c.gst_object_get_parent(b) == null)});
    out("rename after unparent {d} {s}", .{ c.gst_object_set_name(b, null), c.gst_object_get_name(b) });

    const m: [*c]c.GstMiniObject = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(c.GstMiniObject))));
    c.gst_mini_object_init(m, c.GST_MINI_OBJECT_FLAG_LOCKABLE, c.G_TYPE_POINTER, null, null, freeMini);
    out("writable {d}", .{c.gst_mini_object_is_writable(m)});
    out("lock read {d}", .{c.gst_mini_object_lock(m, c.GST_LOCK_FLAG_READ)});
    out("lock write while read {d}", .{c.gst_mini_object_lock(m, c.GST_LOCK_FLAG_WRITE)});
    c.gst_mini_object_unlock(m, c.GST_LOCK_FLAG_READ);
    out("state {d}", .{m.*.lockstate});
    out("excl {d} {d}", .{ c.gst_mini_object_lock(m, c.GST_LOCK_FLAG_EXCLUSIVE), c.gst_mini_object_lock(m, c.GST_LOCK_FLAG_EXCLUSIVE) });
    out("writable shared {d}", .{c.gst_mini_object_is_writable(m)});
    out("write shared {d}", .{c.gst_mini_object_lock(m, c.GST_LOCK_FLAG_WRITE)});
    c.gst_mini_object_unlock(m, c.GST_LOCK_FLAG_EXCLUSIVE);
    c.gst_mini_object_unlock(m, c.GST_LOCK_FLAG_EXCLUSIVE);
    out("state {d}", .{m.*.lockstate});
    const q = c.g_quark_from_static_string("k");
    c.gst_mini_object_set_qdata(m, q, @ptrFromInt(42), null);
    out("qdata {d}", .{@intFromPtr(c.gst_mini_object_get_qdata(m, q))});
    c.gst_mini_object_weak_ref(m, weakNotify, @ptrFromInt(7));
    _ = c.gst_mini_object_ref(m);
    out("refcount {d}", .{m.*.refcount});
    c.gst_mini_object_unref(m);
    c.gst_mini_object_unref(m);
    out("freed {d}", .{freed});
}
