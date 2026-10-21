const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Deque = struct {
    data: [*]u8,
    cap: usize,
    head: usize,
    len: usize,
    size: usize,
    pointers: bool,
    clear: c.GDestroyNotify,
};

const Handle = ?*c.GstVecDeque;

fn of(h: Handle) *Deque {
    return @ptrCast(@alignCast(h.?));
}

fn slot(d: *Deque, i: usize) [*]u8 {
    return d.data + ((d.head + i) % d.cap) * d.size;
}

fn create(size: usize, initial: usize, pointers: bool) Handle {
    const d: *Deque = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Deque))));
    const cap = @max(initial, 1);
    d.* = .{ .data = @ptrCast(c.g_malloc0(cap * size)), .cap = cap, .head = 0, .len = 0, .size = size, .pointers = pointers, .clear = null };
    return @ptrCast(d);
}

fn grow(d: *Deque) void {
    if (d.len < d.cap) return;
    const cap = d.cap * 2;
    const data: [*]u8 = @ptrCast(c.g_malloc0(cap * d.size));
    var i: usize = 0;
    while (i < d.len) : (i += 1) @memcpy(data[i * d.size ..][0..d.size], slot(d, i)[0..d.size]);
    c.g_free(d.data);
    d.data = data;
    d.cap = cap;
    d.head = 0;
}

fn insertAt(d: *Deque, idx: usize, item: [*]const u8) void {
    grow(d);
    var i = d.len;
    while (i > idx) : (i -= 1) @memcpy(slot(d, i)[0..d.size], slot(d, i - 1)[0..d.size]);
    @memcpy(slot(d, idx)[0..d.size], item[0..d.size]);
    d.len += 1;
}

fn removeAt(d: *Deque, idx: usize, out: ?[*]u8) void {
    if (out) |o| @memcpy(o[0..d.size], slot(d, idx)[0..d.size]);
    var i = idx;
    while (i + 1 < d.len) : (i += 1) @memcpy(slot(d, i)[0..d.size], slot(d, i + 1)[0..d.size]);
    d.len -= 1;
    if (d.len == 0) d.head = 0;
}

fn pointerAt(d: *Deque, i: usize) c.gpointer {
    const p: *align(1) c.gpointer = @ptrCast(slot(d, i));
    return p.*;
}

fn element(d: *Deque, i: usize) c.gpointer {
    return if (d.pointers) pointerAt(d, i) else @ptrCast(slot(d, i));
}

fn release(d: *Deque, i: usize) void {
    const f = d.clear orelse return;
    f(element(d, i));
}

pub export fn gst_vec_deque_new(initial: c.gsize) Handle {
    return create(@sizeOf(c.gpointer), initial, true);
}

pub export fn gst_vec_deque_new_for_struct(size: c.gsize, initial: c.gsize) Handle {
    if (!check.that(size != 0, "gst_vec_deque_new_for_struct", "struct_size > 0")) return null;
    return create(size, initial, false);
}

pub export fn gst_vec_deque_set_clear_func(h: Handle, clear: c.GDestroyNotify) void {
    of(h).clear = clear;
}

pub export fn gst_vec_deque_clear(h: Handle) void {
    if (!check.that(h != null, "gst_vec_deque_clear", "array != NULL")) return;
    const d = of(h);
    var i: usize = 0;
    while (i < d.len) : (i += 1) release(d, i);
    d.head = 0;
    d.len = 0;
}

pub export fn gst_vec_deque_free(h: Handle) void {
    if (!check.that(h != null, "gst_vec_deque_free", "array != NULL")) return;
    gst_vec_deque_clear(h);
    c.g_free(of(h).data);
    c.g_free(h);
}

pub export fn gst_vec_deque_get_length(h: Handle) c.gsize {
    if (!check.that(h != null, "gst_vec_deque_get_length", "array != NULL")) return 0;
    return of(h).len;
}

pub export fn gst_vec_deque_is_empty(h: Handle) c.gboolean {
    if (!check.that(h != null, "gst_vec_deque_is_empty", "array != NULL")) return 0;
    return @intFromBool(of(h).len == 0);
}

pub export fn gst_vec_deque_push_tail(h: Handle, data: c.gpointer) void {
    if (!check.that(h != null, "gst_vec_deque_push_tail", "array != NULL")) return;
    const d = of(h);
    var v = data;
    insertAt(d, d.len, @ptrCast(&v));
}

pub export fn gst_vec_deque_push_tail_struct(h: Handle, p: c.gpointer) void {
    if (!check.that(h != null, "gst_vec_deque_push_tail_struct", "array != NULL")) return;
    const d = of(h);
    insertAt(d, d.len, @ptrCast(p));
}

pub export fn gst_vec_deque_peek_head(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_head", "array != NULL")) return null;
    const d = of(h);
    return if (d.len == 0) null else pointerAt(d, 0);
}

pub export fn gst_vec_deque_peek_tail(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_tail", "array != NULL")) return null;
    const d = of(h);
    return if (d.len == 0) null else pointerAt(d, d.len - 1);
}

pub export fn gst_vec_deque_peek_nth(h: Handle, idx: c.gsize) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_nth", "array != NULL")) return null;
    const d = of(h);
    if (!check.that(idx < d.len, "gst_vec_deque_peek_nth", "idx < array->length")) return null;
    return pointerAt(d, idx);
}

pub export fn gst_vec_deque_peek_head_struct(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_head_struct", "array != NULL")) return null;
    const d = of(h);
    return if (d.len == 0) null else @ptrCast(slot(d, 0));
}

pub export fn gst_vec_deque_peek_tail_struct(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_tail_struct", "array != NULL")) return null;
    const d = of(h);
    return if (d.len == 0) null else @ptrCast(slot(d, d.len - 1));
}

pub export fn gst_vec_deque_peek_nth_struct(h: Handle, idx: c.gsize) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_peek_nth_struct", "array != NULL")) return null;
    const d = of(h);
    if (!check.that(idx < d.len, "gst_vec_deque_peek_nth_struct", "idx < array->length")) return null;
    return @ptrCast(slot(d, idx));
}

pub export fn gst_vec_deque_pop_head(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_pop_head", "array != NULL")) return null;
    const d = of(h);
    if (d.len == 0) return null;
    const v = pointerAt(d, 0);
    d.head = (d.head + 1) % d.cap;
    d.len -= 1;
    return v;
}

pub export fn gst_vec_deque_pop_tail(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_pop_tail", "array != NULL")) return null;
    const d = of(h);
    if (d.len == 0) return null;
    d.len -= 1;
    return pointerAt(d, d.len);
}

pub export fn gst_vec_deque_pop_head_struct(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_pop_head_struct", "array != NULL")) return null;
    const d = of(h);
    if (d.len == 0) return null;
    const p = slot(d, 0);
    d.head = (d.head + 1) % d.cap;
    d.len -= 1;
    return @ptrCast(p);
}

pub export fn gst_vec_deque_pop_tail_struct(h: Handle) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_pop_tail_struct", "array != NULL")) return null;
    const d = of(h);
    if (d.len == 0) return null;
    d.len -= 1;
    return @ptrCast(slot(d, d.len));
}

pub export fn gst_vec_deque_drop_element(h: Handle, idx: c.gsize) c.gpointer {
    if (!check.that(h != null, "gst_vec_deque_drop_element", "array != NULL")) return null;
    const d = of(h);
    if (!check.that(idx < d.len, "gst_vec_deque_drop_element", "idx < array->length")) return null;
    var v: c.gpointer = null;
    removeAt(d, idx, @ptrCast(&v));
    return v;
}

pub export fn gst_vec_deque_drop_struct(h: Handle, idx: c.gsize, out: c.gpointer) c.gboolean {
    if (!check.that(h != null, "gst_vec_deque_drop_struct", "array != NULL")) return 0;
    const d = of(h);
    if (!check.that(idx < d.len, "gst_vec_deque_drop_struct", "idx < array->length")) return 0;
    removeAt(d, idx, if (out != null) @as([*]u8, @ptrCast(out)) else null);
    return 1;
}

pub export fn gst_vec_deque_find(h: Handle, func: c.GCompareFunc, data: c.gpointer) c.gsize {
    if (!check.that(h != null, "gst_vec_deque_find", "array != NULL")) return std.math.maxInt(usize);
    const d = of(h);
    var i: usize = 0;
    while (i < d.len) : (i += 1) {
        const e = element(d, i);
        const hit = if (func) |f| f(e, data) == 0 else e == data;
        if (hit) return i;
    }
    return std.math.maxInt(usize);
}

fn sortedIndex(d: *Deque, item: c.gpointer, func: c.GCompareDataFunc, user: c.gpointer) usize {
    const f = func orelse return d.len;
    var i: usize = d.len;
    while (i > 0) : (i -= 1) {
        if (f(element(d, i - 1), item, user) <= 0) break;
    }
    return i;
}

pub export fn gst_vec_deque_push_sorted(h: Handle, data: c.gpointer, func: c.GCompareDataFunc, user: c.gpointer) void {
    if (!check.that(h != null, "gst_vec_deque_push_sorted", "array != NULL")) return;
    if (!check.that(func != null, "gst_vec_deque_push_sorted", "func != NULL")) return;
    const d = of(h);
    var v = data;
    insertAt(d, sortedIndex(d, data, func, user), @ptrCast(&v));
}

pub export fn gst_vec_deque_push_sorted_struct(h: Handle, p: c.gpointer, func: c.GCompareDataFunc, user: c.gpointer) void {
    if (!check.that(h != null, "gst_vec_deque_push_sorted_struct", "array != NULL")) return;
    if (!check.that(func != null, "gst_vec_deque_push_sorted_struct", "func != NULL")) return;
    const d = of(h);
    insertAt(d, sortedIndex(d, p, func, user), @ptrCast(p));
}

pub export fn gst_vec_deque_sort(h: Handle, func: c.GCompareDataFunc, user: c.gpointer) void {
    if (!check.that(h != null, "gst_vec_deque_sort", "array != NULL")) return;
    if (!check.that(func != null, "gst_vec_deque_sort", "compare_func != NULL")) return;
    const d = of(h);
    if (d.len < 2) return;
    const flat: [*]u8 = @ptrCast(c.g_malloc(d.len * d.size));
    defer c.g_free(flat);
    var i: usize = 0;
    while (i < d.len) : (i += 1) @memcpy(flat[i * d.size ..][0..d.size], slot(d, i)[0..d.size]);
    const n = d.len;
    d.len = 0;
    d.head = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const item = flat + i * d.size;
        const key: c.gpointer = if (d.pointers) @as(*align(1) c.gpointer, @ptrCast(item)).* else @ptrCast(item);
        insertAt(d, sortedIndex(d, key, func, user), item);
    }
}
