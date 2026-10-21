const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const info = @import("info.zig");
const mini = @import("mini.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Promise = c.GstPromise;

const Impl = extern struct {
    promise: Promise,
    result: c.GstPromiseResult,
    reply: [*c]c.GstStructure,
    lock: c.GMutex,
    cond: c.GCond,
    change_func: c.GstPromiseChangeFunc,
    user_data: c.gpointer,
    notify: c.GDestroyNotify,
};

var immutable_refcount: c_int = 2;
var type_once: gtype.Once = .{};
var cat_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;

fn impl(p: anytype) *Impl {
    return @ptrCast(@alignCast(p));
}

pub export fn gst_promise_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            return c.g_boxed_type_register_static("GstPromise", @ptrCast(&mini.gst_mini_object_ref), @ptrCast(&mini.gst_mini_object_unref));
        }
    }.f);
}

pub export fn gst_promise_wait(p: [*c]Promise) c.GstPromiseResult {
    if (!check.that(p != null, "gst_promise_wait", "promise != NULL")) return c.GST_PROMISE_RESULT_EXPIRED;
    const d = impl(p);
    c.g_mutex_lock(&d.lock);
    defer c.g_mutex_unlock(&d.lock);
    while (d.result == c.GST_PROMISE_RESULT_PENDING) c.g_cond_wait(&d.cond, &d.lock);
    return d.result;
}

fn notifyChange(p: [*c]Promise, f: c.GstPromiseChangeFunc, data: c.gpointer) void {
    if (f) |func| func(p, data);
}

pub export fn gst_promise_reply(p: [*c]Promise, s: [*c]c.GstStructure) void {
    if (p == null) return;
    const d = impl(p);
    var f: c.GstPromiseChangeFunc = null;
    var data: c.gpointer = null;
    c.g_mutex_lock(&d.lock);
    if (d.result != c.GST_PROMISE_RESULT_PENDING and d.result != c.GST_PROMISE_RESULT_INTERRUPTED) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Promise result isn't PENDING or INTERRUPTED");
        c.g_mutex_unlock(&d.lock);
        return;
    }
    if (d.reply != null and d.reply != s) c.gst_structure_free(d.reply);
    if (d.result == c.GST_PROMISE_RESULT_PENDING) {
        if (s != null and c.gst_structure_set_parent_refcount(s, &immutable_refcount) == 0) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Input structure has a parent already!");
            c.g_mutex_unlock(&d.lock);
            return;
        }
        d.result = c.GST_PROMISE_RESULT_REPLIED;
        d.reply = s;
        f = d.change_func;
        data = d.user_data;
    } else if (s != null) c.gst_structure_free(s);
    c.g_cond_broadcast(&d.cond);
    c.g_mutex_unlock(&d.lock);
    notifyChange(p, f, data);
}

pub export fn gst_promise_get_reply(p: [*c]Promise) [*c]const c.GstStructure {
    if (!check.that(p != null, "gst_promise_get_reply", "promise != NULL")) return null;
    const d = impl(p);
    c.g_mutex_lock(&d.lock);
    if (d.result != c.GST_PROMISE_RESULT_REPLIED) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Promise result isn't REPLIED");
        c.g_mutex_unlock(&d.lock);
        return null;
    }
    c.g_mutex_unlock(&d.lock);
    return d.reply;
}

pub export fn gst_promise_interrupt(p: [*c]Promise) void {
    if (!check.that(p != null, "gst_promise_interrupt", "promise != NULL")) return;
    const d = impl(p);
    var f: c.GstPromiseChangeFunc = null;
    var data: c.gpointer = null;
    c.g_mutex_lock(&d.lock);
    if (d.result != c.GST_PROMISE_RESULT_PENDING and d.result != c.GST_PROMISE_RESULT_REPLIED) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Promise result isn't PENDING or REPLIED");
        c.g_mutex_unlock(&d.lock);
        return;
    }
    if (d.result == c.GST_PROMISE_RESULT_PENDING) {
        d.result = c.GST_PROMISE_RESULT_INTERRUPTED;
        c.g_cond_broadcast(&d.cond);
        f = d.change_func;
        data = d.user_data;
    }
    c.g_mutex_unlock(&d.lock);
    notifyChange(p, f, data);
}

pub export fn gst_promise_expire(p: [*c]Promise) void {
    if (!check.that(p != null, "gst_promise_expire", "promise != NULL")) return;
    const d = impl(p);
    var f: c.GstPromiseChangeFunc = null;
    var data: c.gpointer = null;
    c.g_mutex_lock(&d.lock);
    if (d.result == c.GST_PROMISE_RESULT_PENDING) {
        d.result = c.GST_PROMISE_RESULT_EXPIRED;
        c.g_cond_broadcast(&d.cond);
        f = d.change_func;
        data = d.user_data;
        d.change_func = null;
        d.user_data = null;
    }
    c.g_mutex_unlock(&d.lock);
    notifyChange(p, f, data);
}

fn freeHook(m: [*c]c.GstMiniObject) callconv(.c) void {
    const d = impl(m);
    if (d.result == c.GST_PROMISE_RESULT_PENDING) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: runtime check failed: (%s)", "gst_promise_free", "GST_PROMISE_RESULT (promise) != GST_PROMISE_RESULT_PENDING");
    if (d.notify) |n| n(d.user_data);
    if (d.reply != null) {
        _ = c.gst_structure_set_parent_refcount(d.reply, null);
        c.gst_structure_free(d.reply);
    }
    c.g_mutex_clear(&d.lock);
    c.g_cond_clear(&d.cond);
    c.g_free(d);
}

pub export fn gst_promise_new() [*c]Promise {
    _ = cat_once.get(struct {
        fn f() c.GType {
            debug_cat = info._gst_debug_category_new("gstpromise", 0, "gstpromise");
            return 1;
        }
    }.f);
    const d: *Impl = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Impl))));
    mini.gst_mini_object_init(@ptrCast(d), 0, gst_promise_get_type(), null, null, freeHook);
    d.reply = null;
    d.result = c.GST_PROMISE_RESULT_PENDING;
    c.g_mutex_init(&d.lock);
    c.g_cond_init(&d.cond);
    return @ptrCast(d);
}

pub export fn gst_promise_new_with_change_func(func: c.GstPromiseChangeFunc, data: c.gpointer, notify: c.GDestroyNotify) [*c]Promise {
    const p = gst_promise_new();
    const d = impl(p);
    d.change_func = func;
    d.user_data = data;
    d.notify = notify;
    return p;
}

pub export fn gst_promise_ref(p: [*c]Promise) [*c]Promise {
    return @ptrCast(mini.gst_mini_object_ref(@ptrCast(p)));
}

pub export fn gst_promise_unref(p: [*c]Promise) void {
    mini.gst_mini_object_unref(@ptrCast(p));
}

pub export fn gst_clear_promise(slot: [*c][*c]Promise) void {
    mini.gst_clear_mini_object(@ptrCast(slot));
}
