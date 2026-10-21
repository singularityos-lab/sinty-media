const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const Queue = extern struct {
    refs: std.atomic.Value(c.gint),
    lock: c.GMutex,
    ptr: [*]c.gpointer,
    cap: usize,
    head: usize,
    len: usize,

    fn slots(q: *Queue) []c.gpointer {
        return q.ptr[0..q.cap];
    }

    pub const Header = c.struct__GstAtomicQueue;
};

var type_once: gtype.Once = .{};
const alloc = std.heap.c_allocator;

pub export fn gst_atomic_queue_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstAtomicQueue", @ptrCast(&gst_atomic_queue_ref), @ptrCast(&gst_atomic_queue_unref));
        }
    }.f);
}

fn roundUp(n: usize) usize {
    var r: usize = 1;
    while (r < n) r <<= 1;
    return r;
}

pub export fn gst_atomic_queue_new(initial: c.guint) ?*Queue {
    const q = alloc.create(Queue) catch return null;
    const size = roundUp(@max(initial, 16));
    const buf = alloc.alloc(c.gpointer, size) catch {
        alloc.destroy(q);
        return null;
    };
    q.* = .{ .refs = .init(1), .lock = std.mem.zeroes(c.GMutex), .ptr = buf.ptr, .cap = buf.len, .head = 0, .len = 0 };
    c.g_mutex_init(&q.lock);
    return q;
}

pub export fn gst_atomic_queue_ref(q: ?*Queue) void {
    const r = q orelse return check.fail("gst_atomic_queue_ref", "queue != NULL");
    _ = r.refs.fetchAdd(1, .acq_rel);
}

pub export fn gst_atomic_queue_unref(q: ?*Queue) void {
    const r = q orelse return check.fail("gst_atomic_queue_unref", "queue != NULL");
    if (r.refs.fetchSub(1, .acq_rel) != 1) return;
    c.g_mutex_clear(&r.lock);
    alloc.free(r.slots());
    alloc.destroy(r);
}

pub export fn gst_atomic_queue_peek(q: ?*Queue) c.gpointer {
    const r = q orelse {
        check.fail("gst_atomic_queue_peek", "queue != NULL");
        return null;
    };
    c.g_mutex_lock(&r.lock);
    defer c.g_mutex_unlock(&r.lock);
    if (r.len == 0) return null;
    return r.ptr[r.head];
}

pub export fn gst_atomic_queue_pop(q: ?*Queue) c.gpointer {
    const r = q orelse {
        check.fail("gst_atomic_queue_pop", "queue != NULL");
        return null;
    };
    c.g_mutex_lock(&r.lock);
    defer c.g_mutex_unlock(&r.lock);
    if (r.len == 0) return null;
    const v = r.ptr[r.head];
    r.head = (r.head + 1) & (r.cap - 1);
    r.len -= 1;
    return v;
}

pub export fn gst_atomic_queue_push(q: ?*Queue, data: c.gpointer) void {
    const r = q orelse return check.fail("gst_atomic_queue_push", "queue != NULL");
    c.g_mutex_lock(&r.lock);
    defer c.g_mutex_unlock(&r.lock);
    if (r.len == r.cap) {
        const bigger = alloc.alloc(c.gpointer, r.cap * 2) catch return;
        for (0..r.len) |i| bigger[i] = r.ptr[(r.head + i) & (r.cap - 1)];
        alloc.free(r.slots());
        r.ptr = bigger.ptr;
        r.cap = bigger.len;
        r.head = 0;
    }
    r.ptr[(r.head + r.len) & (r.cap - 1)] = data;
    r.len += 1;
}

pub export fn gst_atomic_queue_length(q: ?*Queue) c.guint {
    const r = q orelse {
        check.fail("gst_atomic_queue_length", "queue != NULL");
        return 0;
    };
    c.g_mutex_lock(&r.lock);
    defer c.g_mutex_unlock(&r.lock);
    return @intCast(r.len);
}
