const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

const It = c.GstIterator;
const Value = c.GValue;

var type_once: gtype.Once = .{};

pub export fn gst_iterator_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstIterator", @ptrCast(&gst_iterator_copy), @ptrCast(&gst_iterator_free));
        }
    }.f);
}

pub export fn gst_iterator_copy(it: [*c]const It) [*c]It {
    const copy: [*c]It = @ptrCast(@alignCast(c.g_memdup2(it, it[0].size)));
    if (it[0].copy) |f| f(it, copy);
    return copy;
}

pub export fn gst_iterator_new(size: c.guint, t: c.GType, lock: [*c]c.GMutex, master: [*c]c.guint32, copy: c.GstIteratorCopyFunction, next: c.GstIteratorNextFunction, item: c.GstIteratorItemFunction, resync: c.GstIteratorResyncFunction, free: c.GstIteratorFreeFunction) [*c]It {
    const f = "gst_iterator_new";
    if (!check.that(size >= @sizeOf(It), f, "size >= sizeof (GstIterator)")) return null;
    if (!check.that(c.g_type_qname(t) != 0, f, "g_type_qname (type) != 0")) return null;
    if (!check.that(master != null, f, "master_cookie != NULL")) return null;
    if (!check.that(next != null, f, "next != NULL")) return null;
    if (!check.that(resync != null, f, "resync != NULL")) return null;
    if (!check.that(free != null, f, "free != NULL")) return null;
    const it: [*c]It = @ptrCast(@alignCast(c.g_malloc0(size)));
    it[0] = .{ .size = size, .type = t, .lock = lock, .master_cookie = master, .cookie = master.*, .copy = copy, .next = next, .item = item, .resync = resync, .free = free, .pushed = null };
    return it;
}

const ListIt = extern struct {
    base: It,
    owner: ?*c.GObject,
    orig: [*c][*c]c.GList,
    list: [*c]c.GList,
    set_value: *const fn ([*c]Value, c.gpointer) callconv(.c) void,
};

fn listCopy(_: [*c]const It, copy: [*c]It) callconv(.c) void {
    const l: *ListIt = @ptrCast(@alignCast(copy));
    if (l.owner) |o| _ = c.g_object_ref(o);
}

fn listNext(it: [*c]It, elem: [*c]Value) callconv(.c) c.GstIteratorResult {
    const l: *ListIt = @ptrCast(@alignCast(it));
    if (l.list == null) return c.GST_ITERATOR_DONE;
    const data = l.list[0].data;
    l.list = l.list[0].next;
    l.set_value(elem, data);
    return c.GST_ITERATOR_OK;
}

fn listResync(it: [*c]It) callconv(.c) void {
    const l: *ListIt = @ptrCast(@alignCast(it));
    l.list = l.orig.*;
}

fn listFree(it: [*c]It) callconv(.c) void {
    const l: *ListIt = @ptrCast(@alignCast(it));
    if (l.owner) |o| c.g_object_unref(o);
}

fn setObject(v: [*c]Value, p: c.gpointer) callconv(.c) void {
    c.g_value_set_object(v, p);
}
fn setBoxed(v: [*c]Value, p: c.gpointer) callconv(.c) void {
    c.g_value_set_boxed(v, p);
}
fn setPointer(v: [*c]Value, p: c.gpointer) callconv(.c) void {
    c.g_value_set_pointer(v, p);
}
fn setString(v: [*c]Value, p: c.gpointer) callconv(.c) void {
    c.g_value_set_string(v, @ptrCast(p));
}

pub export fn gst_iterator_new_list(t: c.GType, lock: [*c]c.GMutex, master: [*c]c.guint32, list: [*c][*c]c.GList, owner: [*c]c.GObject, item: c.GstIteratorItemFunction) [*c]It {
    const setter: *const fn ([*c]Value, c.gpointer) callconv(.c) void = if (c.g_type_is_a(t, c.G_TYPE_OBJECT) != 0)
        setObject
    else if (c.g_type_is_a(t, c.G_TYPE_BOXED) != 0)
        setBoxed
    else if (c.g_type_is_a(t, c.G_TYPE_POINTER) != 0)
        setPointer
    else if (c.g_type_is_a(t, c.G_TYPE_STRING) != 0)
        setString
    else {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "List iterators can only be created for lists containing instances of GObject, boxed types, pointer types and strings");
        return null;
    };
    const it = gst_iterator_new(@sizeOf(ListIt), t, lock, master, @ptrCast(&listCopy), @ptrCast(&listNext), item, @ptrCast(&listResync), @ptrCast(&listFree));
    const l: *ListIt = @ptrCast(@alignCast(it));
    l.owner = if (owner != null) @ptrCast(@alignCast(c.g_object_ref(owner))) else null;
    l.orig = list;
    l.list = list.*;
    l.set_value = setter;
    return it;
}

fn pop(it: [*c]It) void {
    if (it[0].pushed != null) {
        gst_iterator_free(it[0].pushed);
        it[0].pushed = null;
    }
}

fn enter(it: [*c]It) void {
    if (it[0].lock != null) c.g_mutex_lock(it[0].lock);
}

fn leave(it: [*c]It) void {
    if (it[0].lock != null) c.g_mutex_unlock(it[0].lock);
}

pub export fn gst_iterator_next(it: [*c]It, elem: [*c]Value) c.GstIteratorResult {
    const f = "gst_iterator_next";
    if (!check.that(it != null, f, "it != NULL")) return c.GST_ITERATOR_ERROR;
    if (!check.that(elem != null, f, "elem != NULL")) return c.GST_ITERATOR_ERROR;
    if (!check.that(elem[0].g_type == 0 or c.g_type_check_value_holds(elem, it[0].type) != 0, f, "G_VALUE_TYPE (elem) == G_TYPE_INVALID || G_VALUE_HOLDS (elem, it->type)")) return c.GST_ITERATOR_ERROR;
    if (elem[0].g_type == 0) _ = c.g_value_init(elem, it[0].type);
    while (true) {
        if (it[0].pushed != null) {
            const r = gst_iterator_next(it[0].pushed, elem);
            if (r != c.GST_ITERATOR_DONE) return r;
            pop(it);
        }
        enter(it);
        defer leave(it);
        if (it[0].master_cookie.* != it[0].cookie) return c.GST_ITERATOR_RESYNC;
        const r = it[0].next.?(it, elem);
        if (r != c.GST_ITERATOR_OK or it[0].item == null) return r;
        switch (it[0].item.?(it, elem)) {
            c.GST_ITERATOR_ITEM_SKIP => {
                _ = c.g_value_reset(elem);
                continue;
            },
            c.GST_ITERATOR_ITEM_END => {
                _ = c.g_value_reset(elem);
                return c.GST_ITERATOR_DONE;
            },
            else => return r,
        }
    }
}

pub export fn gst_iterator_resync(it: [*c]It) void {
    if (!check.that(it != null, "gst_iterator_resync", "it != NULL")) return;
    pop(it);
    enter(it);
    defer leave(it);
    it[0].resync.?(it);
    it[0].cookie = it[0].master_cookie.*;
}

pub export fn gst_iterator_free(it: [*c]It) void {
    if (!check.that(it != null, "gst_iterator_free", "it != NULL")) return;
    pop(it);
    it[0].free.?(it);
    c.g_free(it);
}

pub export fn gst_iterator_push(it: [*c]It, other: [*c]It) void {
    if (!check.that(it != null, "gst_iterator_push", "it != NULL")) return;
    if (!check.that(other != null, "gst_iterator_push", "other != NULL")) return;
    it[0].pushed = other;
}

const Filter = extern struct {
    base: It,
    inner: [*c]It,
    outer_lock: [*c]c.GMutex,
    func: c.GCompareFunc,
    data: Value,
    has_data: c.gboolean,
};

fn filterNext(it: [*c]It, elem: [*c]Value) callconv(.c) c.GstIteratorResult {
    const fl: *Filter = @ptrCast(@alignCast(it));
    var item = std.mem.zeroes(Value);
    defer if (item.g_type != 0) c.g_value_unset(&item);
    while (true) {
        const r = gst_iterator_next(fl.inner, &item);
        if (r != c.GST_ITERATOR_OK) return r;
        if (fl.outer_lock != null) c.g_mutex_unlock(fl.outer_lock);
        const hit = fl.func.?(&item, &fl.data) == 0;
        if (hit) c.g_value_copy(&item, elem);
        _ = c.g_value_reset(&item);
        if (fl.outer_lock != null) c.g_mutex_lock(fl.outer_lock);
        if (hit) return r;
    }
}

fn filterCopy(src: [*c]const It, dst: [*c]It) callconv(.c) void {
    const a: *const Filter = @ptrCast(@alignCast(src));
    const b: *Filter = @ptrCast(@alignCast(dst));
    b.inner = gst_iterator_copy(a.inner);
    b.outer_lock = if (b.inner[0].lock != null) b.inner[0].lock else a.outer_lock;
    b.inner[0].lock = null;
    if (a.has_data != 0) {
        b.data = std.mem.zeroes(Value);
        _ = c.g_value_init(&b.data, a.data.g_type);
        c.g_value_copy(&a.data, &b.data);
    }
}

fn filterResync(it: [*c]It) callconv(.c) void {
    gst_iterator_resync(@as(*Filter, @ptrCast(@alignCast(it))).inner);
}

fn filterFree(it: [*c]It) callconv(.c) void {
    const fl: *Filter = @ptrCast(@alignCast(it));
    if (fl.has_data != 0) c.g_value_unset(&fl.data);
    gst_iterator_free(fl.inner);
}

pub export fn gst_iterator_filter(it: [*c]It, func: c.GCompareFunc, data: [*c]const Value) [*c]It {
    if (!check.that(it != null, "gst_iterator_filter", "it != NULL")) return null;
    if (!check.that(func != null, "gst_iterator_filter", "func != NULL")) return null;
    const out = gst_iterator_new(@sizeOf(Filter), it[0].type, it[0].lock, it[0].master_cookie, @ptrCast(&filterCopy), @ptrCast(&filterNext), null, @ptrCast(&filterResync), @ptrCast(&filterFree));
    const fl: *Filter = @ptrCast(@alignCast(out));
    fl.outer_lock = it[0].lock;
    it[0].lock = null;
    fl.func = func;
    if (data != null) {
        _ = c.g_value_init(&fl.data, data[0].g_type);
        c.g_value_copy(data, &fl.data);
        fl.has_data = 1;
    } else fl.has_data = 0;
    fl.inner = it;
    return out;
}

pub export fn gst_iterator_fold(it: [*c]It, func: c.GstIteratorFoldFunction, ret: [*c]Value, data: c.gpointer) c.GstIteratorResult {
    if (!check.that(it != null, "gst_iterator_fold", "it != NULL")) return c.GST_ITERATOR_ERROR;
    var item = std.mem.zeroes(Value);
    defer if (item.g_type != 0) c.g_value_unset(&item);
    while (true) {
        const r = gst_iterator_next(it, &item);
        if (r != c.GST_ITERATOR_OK) return r;
        if (func.?(&item, ret, data) == 0) return r;
        _ = c.g_value_reset(&item);
    }
}

const Each = struct { func: c.GstIteratorForeachFunction, data: c.gpointer };

fn eachStep(item: [*c]const Value, _: [*c]Value, data: c.gpointer) callconv(.c) c.gboolean {
    const e: *Each = @ptrCast(@alignCast(data));
    e.func.?(item, e.data);
    return 1;
}

pub export fn gst_iterator_foreach(it: [*c]It, func: c.GstIteratorForeachFunction, data: c.gpointer) c.GstIteratorResult {
    var e = Each{ .func = func, .data = data };
    return gst_iterator_fold(it, eachStep, null, &e);
}

const Find = struct { func: c.GCompareFunc, data: c.gpointer, found: bool = false };

fn findStep(item: [*c]const Value, ret: [*c]Value, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Find = @ptrCast(@alignCast(data));
    if (f.func.?(item, f.data) != 0) return 1;
    f.found = true;
    c.g_value_copy(item, ret);
    return 0;
}

pub export fn gst_iterator_find_custom(it: [*c]It, func: c.GCompareFunc, elem: [*c]Value, data: c.gpointer) c.gboolean {
    if (!check.that(elem[0].g_type == 0 or c.g_type_check_value_holds(elem, it[0].type) != 0, "gst_iterator_find_custom", "G_VALUE_TYPE (elem) == G_TYPE_INVALID || G_VALUE_HOLDS (elem, it->type)")) return c.GST_ITERATOR_ERROR;
    if (elem[0].g_type == 0) _ = c.g_value_init(elem, it[0].type);
    var f = Find{ .func = func, .data = data };
    while (gst_iterator_fold(it, findStep, elem, &f) == c.GST_ITERATOR_RESYNC) gst_iterator_resync(it);
    if (!f.found) c.g_value_unset(elem);
    return @intFromBool(f.found);
}

const Single = extern struct {
    base: It,
    object: Value,
    visited: c.gboolean,
    empty: c.gboolean,
};

var single_cookie: c.guint32 = 0;

fn singleCopy(src: [*c]const It, dst: [*c]It) callconv(.c) void {
    const a: *const Single = @ptrCast(@alignCast(src));
    const b: *Single = @ptrCast(@alignCast(dst));
    if (a.empty != 0) return;
    b.object = std.mem.zeroes(Value);
    _ = c.g_value_init(&b.object, a.base.type);
    c.g_value_copy(&a.object, &b.object);
}

fn singleNext(it: [*c]It, out: [*c]Value) callconv(.c) c.GstIteratorResult {
    const s: *Single = @ptrCast(@alignCast(it));
    if (s.visited != 0 or s.empty != 0) return c.GST_ITERATOR_DONE;
    c.g_value_copy(&s.object, out);
    s.visited = 1;
    return c.GST_ITERATOR_OK;
}

fn singleResync(it: [*c]It) callconv(.c) void {
    @as(*Single, @ptrCast(@alignCast(it))).visited = 0;
}

fn singleFree(it: [*c]It) callconv(.c) void {
    const s: *Single = @ptrCast(@alignCast(it));
    if (s.empty == 0) c.g_value_unset(&s.object);
}

pub export fn gst_iterator_new_single(t: c.GType, object: [*c]const Value) [*c]It {
    const it = gst_iterator_new(@sizeOf(Single), t, null, &single_cookie, @ptrCast(&singleCopy), @ptrCast(&singleNext), null, @ptrCast(&singleResync), @ptrCast(&singleFree));
    const s: *Single = @ptrCast(@alignCast(it));
    if (object != null) {
        _ = c.g_value_init(&s.object, t);
        c.g_value_copy(object, &s.object);
        s.empty = 0;
    } else s.empty = 1;
    s.visited = 0;
    return it;
}
