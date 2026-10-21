const std = @import("std");
const c = @import("c.zig").c;
const gtype = @import("gtype.zig");
const check = @import("check.zig");
const tracer = @import("tracer.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Mini = c.GstMiniObject;

const LOCK_ONE: c.guint = 0x100;
const SHARE_ONE: c.guint = 0x10000;
const MODE_MASK: c.guint = 0xff;
const ACCESS_MASK: c.guint = 0xff;

const State = enum(c.guint) { bare = 1, one_parent = 2, extra = 3 };

const Slot = struct {
    quark: c.GQuark,
    notify: c.GstMiniObjectNotify,
    data: c.gpointer,
    destroy: c.GDestroyNotify,
};

const Extra = struct {
    parents: std.ArrayListUnmanaged(*Mini) = .empty,
    slots: std.ArrayListUnmanaged(Slot) = .empty,
};

const gpa = std.heap.c_allocator;

var guard: c.GRecMutex = std.mem.zeroes(c.GRecMutex);
var weak_quark: c.GQuark = 0;

pub export var _gst_mini_object_type: c.GType = 0;

var type_once: gtype.Once = .{};

fn registerType() c.GType {
    return c.g_boxed_type_register_static("GstMiniObject", @ptrCast(&gst_mini_object_ref), @ptrCast(&gst_mini_object_unref));
}

pub export fn gst_mini_object_get_type() c.GType {
    return type_once.get(registerType);
}

pub fn initialize() void {
    _gst_mini_object_type = gst_mini_object_get_type();
    weak_quark = c.g_quark_from_static_string("GstMiniObjectWeakRefQuark");
}

fn lockGuard() void {
    c.g_rec_mutex_lock(&guard);
}

fn unlockGuard() void {
    c.g_rec_mutex_unlock(&guard);
}

fn state(m: *const Mini) State {
    return @enumFromInt(@atomicLoad(c.guint, @constCast(&m.priv_uint), .acquire));
}

fn setState(m: *Mini, s: State) void {
    @atomicStore(c.guint, &m.priv_uint, @intFromEnum(s), .release);
}

fn extraOf(m: *const Mini) *Extra {
    return @ptrCast(@alignCast(m.priv_pointer));
}

fn promote(m: *Mini) *Extra {
    if (state(m) == .extra) return extraOf(m);
    const x = gpa.create(Extra) catch @panic("out of memory");
    x.* = .{};
    if (state(m) == .one_parent) x.parents.append(gpa, @ptrCast(@alignCast(m.priv_pointer))) catch @panic("out of memory");
    m.priv_pointer = x;
    setState(m, .extra);
    return x;
}

fn mini(p: anytype) ?*Mini {
    return @ptrCast(@alignCast(@constCast(p)));
}

pub export fn gst_mini_object_init(m: [*c]Mini, flags: c.guint, t: c.GType, copy: c.GstMiniObjectCopyFunction, dispose: c.GstMiniObjectDisposeFunction, free: c.GstMiniObjectFreeFunction) void {
    m.*.type = t;
    m.*.refcount = 1;
    m.*.lockstate = 0;
    m.*.flags = flags;
    m.*.copy = copy;
    m.*.dispose = dispose;
    m.*.free = free;
    m.*.priv_pointer = null;
    setState(m, .bare);
    tracer.emit(.mini_object_created, .{m});
}

pub export fn gst_mini_object_copy(m: [*c]const Mini) [*c]Mini {
    if (!check.that(m != null, "gst_mini_object_copy", "mini_object != NULL")) return null;
    const f = m.*.copy orelse return null;
    return f(m);
}

fn isShared(s: c.guint) bool {
    return s >= 2 * SHARE_ONE;
}

pub export fn gst_mini_object_lock(m: [*c]Mini, flags: c.GstLockFlags) c.gboolean {
    const func = "gst_mini_object_lock";
    if (!check.that(m != null, func, "object != NULL")) return 0;
    if (!check.that(m.*.flags & c.GST_MINI_OBJECT_FLAG_LOCKABLE != 0, func, "GST_MINI_OBJECT_IS_LOCKABLE (object)")) return 0;
    if (m.*.flags & c.GST_MINI_OBJECT_FLAG_LOCK_READONLY != 0 and flags & c.GST_LOCK_FLAG_WRITE != 0) return 0;
    while (true) {
        const old = @atomicLoad(c.gint, &m.*.lockstate, .acquire);
        const cur: c.guint = @bitCast(old);
        var next = cur;
        var mode = flags & ACCESS_MASK;
        if (mode & c.GST_LOCK_FLAG_EXCLUSIVE != 0) {
            next += SHARE_ONE;
            mode &= ~@as(c.guint, c.GST_LOCK_FLAG_EXCLUSIVE);
        }
        const wants_write = (cur & c.GST_LOCK_FLAG_WRITE) != 0 or (mode & c.GST_LOCK_FLAG_WRITE) != 0;
        if (wants_write and isShared(next)) return 0;
        if (mode != 0) {
            if (cur & (SHARE_ONE - 1) == 0) {
                next |= mode;
            } else if (cur & mode != mode) return 0;
            next += LOCK_ONE;
        }
        if (@cmpxchgWeak(c.gint, &m.*.lockstate, old, @bitCast(next), .acq_rel, .acquire) == null) return 1;
    }
}

pub export fn gst_mini_object_unlock(m: [*c]Mini, flags: c.GstLockFlags) void {
    const func = "gst_mini_object_unlock";
    if (!check.that(m != null, func, "object != NULL")) return;
    if (!check.that(m.*.flags & c.GST_MINI_OBJECT_FLAG_LOCKABLE != 0, func, "GST_MINI_OBJECT_IS_LOCKABLE (object)")) return;
    while (true) {
        const old = @atomicLoad(c.gint, &m.*.lockstate, .acquire);
        const cur: c.guint = @bitCast(old);
        var next = cur;
        var mode = flags & ACCESS_MASK;
        if (mode & c.GST_LOCK_FLAG_EXCLUSIVE != 0) {
            if (!check.that(cur >= SHARE_ONE, func, "state >= SHARE_ONE")) return;
            next -= SHARE_ONE;
            mode &= ~@as(c.guint, c.GST_LOCK_FLAG_EXCLUSIVE);
        }
        if (mode != 0) {
            if (!check.that(cur & mode == mode, func, "(state & access_mode) == access_mode")) return;
            next -%= LOCK_ONE;
            if (next & (SHARE_ONE - 1) == mode) next &= ~(SHARE_ONE - 1);
        }
        if (@cmpxchgWeak(c.gint, &m.*.lockstate, old, @bitCast(next), .acq_rel, .acquire) == null) return;
    }
}

pub export fn gst_mini_object_is_writable(m: [*c]const Mini) c.gboolean {
    if (!check.that(m != null, "gst_mini_object_is_writable", "mini_object != NULL")) return 0;
    const own = if (m.*.flags & c.GST_MINI_OBJECT_FLAG_LOCKABLE != 0)
        !isShared(@bitCast(@atomicLoad(c.gint, @constCast(&m.*.lockstate), .acquire)))
    else
        @atomicLoad(c.gint, @constCast(&m.*.refcount), .acquire) == 1;
    if (!own) return 0;
    if (state(m) == .bare) return 1;
    lockGuard();
    defer unlockGuard();
    return switch (state(m)) {
        .bare => 1,
        .one_parent => gst_mini_object_is_writable(@ptrCast(@alignCast(m.*.priv_pointer))),
        .extra => switch (extraOf(m).parents.items.len) {
            0 => 1,
            1 => gst_mini_object_is_writable(extraOf(m).parents.items[0]),
            else => 0,
        },
    };
}

pub export fn gst_mini_object_make_writable(m: [*c]Mini) [*c]Mini {
    if (!check.that(m != null, "gst_mini_object_make_writable", "mini_object != NULL")) return null;
    if (gst_mini_object_is_writable(m) != 0) return m;
    const copy = gst_mini_object_copy(m);
    gst_mini_object_unref(m);
    return copy;
}

pub export fn gst_mini_object_ref(m: [*c]Mini) [*c]Mini {
    if (!check.that(m != null, "gst_mini_object_ref", "mini_object != NULL")) return null;
    const before = @atomicRmw(c.gint, &m.*.refcount, .Add, 1, .acq_rel);
    tracer.emit(.mini_object_reffed, .{ m, before + 1 });
    return m;
}

fn release(m: *Mini) void {
    switch (state(m)) {
        .bare => {},
        .one_parent => c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: object finalizing but still has parent (object:%p, parent:%p)", "free_priv_data", m, m.priv_pointer),
        .extra => {
            const x = extraOf(m);
            for (x.slots.items) |s| {
                if (s.quark == weak_quark) s.notify.?(s.data, m);
                if (s.destroy) |d| d(s.data);
            }
            if (x.parents.items.len != 0) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: object finalizing but still has %d parents (object:%p)", "free_priv_data", @as(c_uint, @intCast(x.parents.items.len)), m);
            x.slots.deinit(gpa);
            x.parents.deinit(gpa);
            gpa.destroy(x);
        },
    }
}

pub export fn gst_mini_object_unref(m: [*c]Mini) void {
    if (m == null) return;
    const func = "gst_mini_object_unref";
    if (!check.that(@atomicLoad(c.gint, &m.*.refcount, .acquire) > 0, func, "GST_MINI_OBJECT_REFCOUNT_VALUE (mini_object) > 0")) return;
    const before = @atomicRmw(c.gint, &m.*.refcount, .Sub, 1, .acq_rel);
    if (!check.that(before > 0, func, "old_refcount > 0")) return;
    tracer.emit(.mini_object_unreffed, .{ m, before - 1 });
    if (before != 1) return;
    const keep_going = if (m.*.dispose) |d| d(m) != 0 else true;
    if (!keep_going) return;
    if (!check.that((@as(c.guint, @bitCast(@atomicLoad(c.gint, &m.*.lockstate, .acquire))) & (SHARE_ONE - LOCK_ONE)) < 4, func, "(g_atomic_int_get (&mini_object->lockstate) & LOCK_MASK) < 4")) return;
    release(m);
    tracer.emit(.mini_object_destroyed, .{m});
    if (m.*.free) |f| f(m);
}

pub export fn gst_clear_mini_object(slot: [*c][*c]Mini) void {
    const m = slot.*;
    if (m != null) {
        slot.* = null;
        gst_mini_object_unref(m);
    }
}

pub export fn gst_mini_object_replace(slot: [*c][*c]Mini, new: [*c]Mini) c.gboolean {
    if (!check.that(slot != null, "gst_mini_object_replace", "olddata != NULL")) return 0;
    const p: *?*Mini = @ptrCast(slot);
    var old = @atomicLoad(?*Mini, p, .acquire);
    if (old == mini(new)) return 0;
    if (new != null) _ = gst_mini_object_ref(new);
    while (@cmpxchgWeak(?*Mini, p, old, mini(new), .acq_rel, .acquire)) |seen| {
        old = seen;
        if (old == mini(new)) break;
    }
    if (old) |o| gst_mini_object_unref(o);
    return @intFromBool(old != mini(new));
}

pub export fn gst_mini_object_steal(slot: [*c][*c]Mini) [*c]Mini {
    if (!check.that(slot != null, "gst_mini_object_steal", "olddata != NULL")) return null;
    const p: *?*Mini = @ptrCast(slot);
    return @atomicRmw(?*Mini, p, .Xchg, null, .acq_rel);
}

pub export fn gst_mini_object_take(slot: [*c][*c]Mini, new: [*c]Mini) c.gboolean {
    if (!check.that(slot != null, "gst_mini_object_take", "olddata != NULL")) return 0;
    const p: *?*Mini = @ptrCast(slot);
    var old = @atomicLoad(?*Mini, p, .acquire);
    while (old != mini(new)) {
        old = @cmpxchgWeak(?*Mini, p, old, mini(new), .acq_rel, .acquire) orelse break;
    }
    if (old) |o| gst_mini_object_unref(o);
    return @intFromBool(old != mini(new));
}

fn find(m: *Mini, quark: c.GQuark, notify: c.GstMiniObjectNotify, data: c.gpointer, exact: bool) ?usize {
    if (state(m) != .extra) return null;
    for (extraOf(m).slots.items, 0..) |s, i| {
        if (s.quark != quark) continue;
        if (!exact or (s.notify == notify and s.data == data)) return i;
    }
    return null;
}

fn drop(m: *Mini, i: usize) void {
    const x = extraOf(m);
    _ = x.slots.swapRemove(i);
    if (x.slots.items.len == 0) x.slots.clearAndFree(gpa);
}

fn put(m: *Mini, at: ?usize, s: Slot) void {
    const x = promote(m);
    if (at) |i| {
        x.slots.items[i] = s;
    } else x.slots.append(gpa, s) catch @panic("out of memory");
}

pub export fn gst_mini_object_weak_ref(m: [*c]Mini, notify: c.GstMiniObjectNotify, data: c.gpointer) void {
    const func = "gst_mini_object_weak_ref";
    if (!check.that(m != null, func, "object != NULL")) return;
    if (!check.that(notify != null, func, "notify != NULL")) return;
    if (!check.that(@atomicLoad(c.gint, &m.*.refcount, .acquire) >= 1, func, "GST_MINI_OBJECT_REFCOUNT_VALUE (object) >= 1")) return;
    lockGuard();
    defer unlockGuard();
    put(m, null, .{ .quark = weak_quark, .notify = notify, .data = data, .destroy = null });
}

pub export fn gst_mini_object_weak_unref(m: [*c]Mini, notify: c.GstMiniObjectNotify, data: c.gpointer) void {
    const func = "gst_mini_object_weak_unref";
    if (!check.that(m != null, func, "object != NULL")) return;
    if (!check.that(notify != null, func, "notify != NULL")) return;
    lockGuard();
    defer unlockGuard();
    if (find(m, weak_quark, notify, data, true)) |i| {
        drop(m, i);
    } else c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: couldn't find weak ref %p (object:%p data:%p)", func.ptr, notify, m, data);
}

pub export fn gst_mini_object_set_qdata(m: [*c]Mini, quark: c.GQuark, data: c.gpointer, destroy: c.GDestroyNotify) void {
    const func = "gst_mini_object_set_qdata";
    if (!check.that(m != null, func, "object != NULL")) return;
    if (!check.that(quark > 0, func, "quark > 0")) return;
    var old: ?Slot = null;
    lockGuard();
    const at = find(m, quark, null, null, false);
    if (at) |i| {
        old = extraOf(m).slots.items[i];
        if (data == null) drop(m, i);
    }
    if (data != null) put(m, at, .{ .quark = quark, .notify = null, .data = data, .destroy = destroy });
    unlockGuard();
    if (old) |o| if (o.destroy) |d| d(o.data);
}

pub export fn gst_mini_object_get_qdata(m: [*c]Mini, quark: c.GQuark) c.gpointer {
    const func = "gst_mini_object_get_qdata";
    if (!check.that(m != null, func, "object != NULL")) return null;
    if (!check.that(quark > 0, func, "quark > 0")) return null;
    lockGuard();
    defer unlockGuard();
    const i = find(m, quark, null, null, false) orelse return null;
    return extraOf(m).slots.items[i].data;
}

pub export fn gst_mini_object_steal_qdata(m: [*c]Mini, quark: c.GQuark) c.gpointer {
    const func = "gst_mini_object_steal_qdata";
    if (!check.that(m != null, func, "object != NULL")) return null;
    if (!check.that(quark > 0, func, "quark > 0")) return null;
    lockGuard();
    defer unlockGuard();
    const i = find(m, quark, null, null, false) orelse return null;
    const d = extraOf(m).slots.items[i].data;
    drop(m, i);
    return d;
}

pub export fn gst_mini_object_add_parent(m: [*c]Mini, parent: [*c]Mini) void {
    if (!check.that(m != null, "gst_mini_object_add_parent", "object != NULL")) return;
    lockGuard();
    defer unlockGuard();
    switch (state(m)) {
        .bare => {
            m.*.priv_pointer = parent;
            setState(m, .one_parent);
        },
        else => promote(m).parents.append(gpa, @ptrCast(parent)) catch @panic("out of memory"),
    }
}

pub export fn gst_mini_object_remove_parent(m: [*c]Mini, parent: [*c]Mini) void {
    const func = "gst_mini_object_remove_parent";
    if (!check.that(m != null, func, "object != NULL")) return;
    lockGuard();
    defer unlockGuard();
    switch (state(m)) {
        .bare => {},
        .one_parent => if (m.*.priv_pointer == @as(c.gpointer, parent)) {
            m.*.priv_pointer = null;
            setState(m, .bare);
        } else c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: couldn't find parent %p (object:%p)", func.ptr, m, parent),
        .extra => {
            const x = extraOf(m);
            for (x.parents.items, 0..) |p, i| {
                if (p == mini(parent)) {
                    _ = x.parents.swapRemove(i);
                    return;
                }
            }
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: couldn't find parent %p (object:%p)", func.ptr, m, parent);
        },
    }
}
