const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const mini = @import("mini.zig");
const buffer = @import("buffer.zig");

comptime {
    @import("abi.zig").check(@This());
}

const List = c.GstBufferList;
const Buffer = c.GstBuffer;
const Mini = c.GstMiniObject;

const Impl = extern struct {
    mini: Mini,
    items: [*c][*c]Buffer,
    len: c.guint,
    cap: c.guint,
};

pub export var _gst_buffer_list_type: c.GType = 0;
var type_once: gtype.Once = .{};

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn asMini(p: anytype) [*c]Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

fn isList(p: anytype) bool {
    return p != null and asMini(p)[0].type == _gst_buffer_list_type;
}

fn roundUp16(n: c.guint) c.guint {
    return (n + 15) & ~@as(c.guint, 15);
}

pub export fn gst_buffer_list_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstBufferList", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub fn initialize() void {
    _gst_buffer_list_type = gst_buffer_list_get_type();
}

fn adopt(l: anytype, b: [*c]Buffer) void {
    mini.gst_mini_object_add_parent(asMini(b), asMini(l));
}

fn release(l: anytype, b: [*c]Buffer) void {
    mini.gst_mini_object_remove_parent(asMini(b), asMini(l));
}

fn copyHook(src: [*c]const Mini) callconv(.c) [*c]Mini {
    const s = impl(src);
    const out = gst_buffer_list_new_sized(s.cap);
    for (0..s.len) |i| {
        impl(out).items[i] = buffer.gst_buffer_ref(s.items[i]);
        adopt(out, impl(out).items[i]);
    }
    impl(out).len = s.len;
    return asMini(out);
}

fn freeHook(m: [*c]Mini) callconv(.c) void {
    const l = impl(m);
    for (0..l.len) |i| {
        release(m, l.items[i]);
        buffer.gst_buffer_unref(l.items[i]);
    }
    c.g_free(@ptrCast(l.items));
    c.g_free(m);
}

pub export fn gst_buffer_list_new_sized(size_in: c.guint) ?*List {
    const cap = roundUp16(if (size_in == 0) 1 else size_in);
    const l: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    mini.gst_mini_object_init(asMini(l), 0, _gst_buffer_list_type, copyHook, null, freeHook);
    l.items = @ptrCast(@alignCast(c.g_malloc0(@as(usize, cap) * @sizeOf([*c]Buffer))));
    l.len = 0;
    l.cap = cap;
    return @ptrCast(l);
}

pub export fn gst_buffer_list_new() ?*List {
    return gst_buffer_list_new_sized(8);
}

pub export fn gst_buffer_list_length(l: ?*List) c.guint {
    if (!check.that(isList(l), "gst_buffer_list_length", "GST_IS_BUFFER_LIST (list)")) return 0;
    return impl(l).len;
}

fn cut(l: ?*List, idx: c.guint, length: c.guint, unref: bool) void {
    const i = impl(l);
    if (unref) for (i.items[idx .. idx + length]) |b| {
        release(l, b);
        buffer.gst_buffer_unref(b);
    };
    if (idx + length != i.len) std.mem.copyForwards([*c]Buffer, i.items[idx .. i.len - length], i.items[idx + length .. i.len]);
    i.len -= length;
}

pub export fn gst_buffer_list_foreach(l: ?*List, func: c.GstBufferListFunc, data: c.gpointer) c.gboolean {
    if (!check.that(isList(l), "gst_buffer_list_foreach", "GST_IS_BUFFER_LIST (list)")) return 0;
    if (!check.that(func != null, "gst_buffer_list_foreach", "func != NULL")) return 0;
    const list_writable = gst_buffer_list_is_writable(l) != 0;
    var warned = false;
    var len = impl(l).len;
    var i: c.guint = 0;
    var ret: c.gboolean = 1;
    while (i < len) {
        const b = impl(l).items[i];
        var out = b;
        const was_writable = list_writable and buffer.gst_buffer_is_writable(b) != 0;
        if (was_writable) release(l, b) else _ = buffer.gst_buffer_ref(b);
        ret = func.?(&out, i, data);
        if (b != out) {
            if (!list_writable) {
                if (!warned) {
                    c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "gst_buffer_list_foreach: non-writable list %p was changed from callback", l);
                    warned = true;
                }
                if (out != null) buffer.gst_buffer_unref(out);
            } else if (out == null) {
                cut(l, i, 1, !was_writable);
                len -= 1;
            } else {
                if (!was_writable) {
                    release(l, b);
                    buffer.gst_buffer_unref(b);
                }
                impl(l).items[i] = out;
                adopt(l, out);
            }
        } else if (was_writable) adopt(l, b) else buffer.gst_buffer_unref(b);
        if (ret == 0) break;
        if (out != null) i += 1;
    }
    return ret;
}

pub export fn gst_buffer_list_get(l: ?*List, idx: c.guint) [*c]Buffer {
    if (!check.that(isList(l), "gst_buffer_list_get", "GST_IS_BUFFER_LIST (list)")) return null;
    if (!check.that(idx < impl(l).len, "gst_buffer_list_get", "idx < list->n_buffers")) return null;
    return impl(l).items[idx];
}

pub export fn gst_buffer_list_get_writable(l: ?*List, idx: c.guint) [*c]Buffer {
    const f = "gst_buffer_list_get_writable";
    if (!check.that(isList(l), f, "GST_IS_BUFFER_LIST (list)")) return null;
    if (!check.that(gst_buffer_list_is_writable(l) != 0, f, "gst_buffer_list_is_writable (list)")) return null;
    if (!check.that(idx < impl(l).len, f, "idx < list->n_buffers")) return null;
    const b = impl(l).items[idx];
    if (buffer.gst_buffer_is_writable(b) != 0) return b;
    release(l, b);
    const fresh = buffer.gst_buffer_copy(b);
    adopt(l, fresh);
    buffer.gst_buffer_unref(b);
    impl(l).items[idx] = fresh;
    return fresh;
}

pub export fn gst_buffer_list_insert(l: ?*List, idx_in: c.gint, b: [*c]Buffer) void {
    const f = "gst_buffer_list_insert";
    if (!check.that(isList(l), f, "GST_IS_BUFFER_LIST (list)")) return;
    if (!check.that(b != null, f, "buffer != NULL")) return;
    if (!check.that(gst_buffer_list_is_writable(l) != 0, f, "gst_buffer_list_is_writable (list)")) return;
    const i = impl(l);
    if (idx_in == -1 and i.len < i.cap) {
        adopt(l, b);
        i.items[i.len] = b;
        i.len += 1;
        return;
    }
    const idx: c.guint = if (idx_in == -1 or idx_in > i.len) i.len else @intCast(idx_in);
    if (i.len + 1 > i.cap) {
        if (i.cap > std.math.maxInt(c.guint) / 2) c.g_log("GStreamer", c.G_LOG_LEVEL_ERROR, "Growing GstBufferList would result in overflow");
        const want = @max(roundUp16(i.len + 1), i.cap * 2);
        i.items = @ptrCast(@alignCast(c.g_realloc(@ptrCast(i.items), @as(usize, want) * @sizeOf([*c]Buffer))));
        i.cap = want;
    }
    if (idx < i.len) std.mem.copyBackwards([*c]Buffer, i.items[idx + 1 .. i.len + 1], i.items[idx..i.len]);
    i.len += 1;
    i.items[idx] = b;
    adopt(l, b);
}

pub export fn gst_buffer_list_remove(l: ?*List, idx: c.guint, length: c.guint) void {
    const f = "gst_buffer_list_remove";
    if (!check.that(isList(l), f, "GST_IS_BUFFER_LIST (list)")) return;
    if (!check.that(idx < impl(l).len, f, "idx < list->n_buffers")) return;
    if (!check.that(idx + length <= impl(l).len, f, "idx + length <= list->n_buffers")) return;
    if (!check.that(gst_buffer_list_is_writable(l) != 0, f, "gst_buffer_list_is_writable (list)")) return;
    cut(l, idx, length, true);
}

pub export fn gst_buffer_list_copy_deep(l: ?*const List) ?*List {
    if (!check.that(isList(l), "gst_buffer_list_copy_deep", "GST_IS_BUFFER_LIST (list)")) return null;
    const out = gst_buffer_list_new();
    for (0..impl(l).len) |i| {
        const old = impl(l).items[i];
        const fresh = buffer.gst_buffer_copy_deep(old);
        if (fresh != null) gst_buffer_list_insert(out, @intCast(i), fresh) else c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Failed to deep copy buffer %p while deep copying buffer list %p. Buffer list copy will be incomplete", old, l);
    }
    return out;
}

pub export fn gst_buffer_list_calculate_size(l: ?*List) c.gsize {
    if (!check.that(isList(l), "gst_buffer_list_calculate_size", "GST_IS_BUFFER_LIST (list)")) return 0;
    var size: c.gsize = 0;
    for (impl(l).items[0..impl(l).len]) |b| size += buffer.gst_buffer_get_size(b);
    return size;
}

pub export fn gst_buffer_list_ref(l: ?*List) ?*List {
    return @ptrCast(mini.gst_mini_object_ref(asMini(l)));
}

pub export fn gst_buffer_list_unref(l: ?*List) void {
    mini.gst_mini_object_unref(asMini(l));
}

pub export fn gst_clear_buffer_list(slot: [*c]?*List) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}

pub export fn gst_buffer_list_copy(l: ?*const List) ?*List {
    return @ptrCast(mini.gst_mini_object_copy(asMini(l)));
}

pub export fn gst_buffer_list_replace(slot: [*c]?*List, l: ?*List) c.gboolean {
    return mini.gst_mini_object_replace(@ptrCast(slot), asMini(l));
}

pub export fn gst_buffer_list_take(slot: [*c]?*List, l: ?*List) c.gboolean {
    return mini.gst_mini_object_take(@ptrCast(slot), asMini(l));
}

pub export fn gst_buffer_list_steal(slot: [*c]?*List) ?*List {
    return @ptrCast(mini.gst_mini_object_steal(@ptrCast(slot)));
}

pub export fn gst_buffer_list_is_writable(l: ?*const List) c.gboolean {
    return mini.gst_mini_object_is_writable(asMini(l));
}

pub export fn gst_buffer_list_make_writable(l: ?*List) ?*List {
    return @ptrCast(mini.gst_mini_object_make_writable(asMini(l)));
}
