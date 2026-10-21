const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const message = @import("message.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Bus = c.GstBus;
const Message = c.GstMessage;
const NONE: u64 = std.math.maxInt(u64);
const ASYNC_DELIVERY: c.guint = c.GST_MINI_OBJECT_FLAG_LAST;

const Handler = struct {
    func: c.GstBusSyncHandler,
    data: c.gpointer,
    notify: c.GDestroyNotify,
    refs: c.gint,
};

const Private = extern struct {
    queue_lock: c.GMutex,
    queue: ?*c.GstVecDeque,
    handler: ?*Handler,
    signal_watchers: c.guint,
    sync_emitters: c.guint,
    source: [*c]c.GSource,
    enable_async: c.gboolean,
    poll: ?*c.GstPoll,
    pollfd: c.GPollFD,
};

const Source = extern struct {
    source: c.GSource,
    bus: [*c]Bus,
};

const PROP_ENABLE_ASYNC = 1;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var sync_signal: c.guint = 0;
var async_signal: c.guint = 0;
var source_funcs: c.GSourceFuncs = .{ .prepare = null, .check = sourceCheck, .dispatch = sourceDispatch, .finalize = sourceFinalize, .closure_callback = null, .closure_marshal = null };

fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

fn isBus(p: anytype) bool {
    return gtype.instanceOf(p, gst_bus_get_type());
}

fn handlerRef(h: *Handler) *Handler {
    _ = @atomicRmw(c.gint, &h.refs, .Add, 1, .seq_cst);
    return h;
}

fn handlerUnref(h: *Handler) void {
    if (@atomicRmw(c.gint, &h.refs, .Sub, 1, .seq_cst) != 1) return;
    if (h.notify) |n| n(h.data);
    std.heap.c_allocator.destroy(h);
}

fn log(p: [*c]Bus, comptime func: [:0]const u8, comptime text: [:0]const u8) void {
    info.gst_debug_log(info.GST_CAT_BUS, c.GST_LEVEL_ERROR, "../gst/gstbus.c", func, 0, @ptrCast(p), text);
}

pub export fn gst_bus_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(object.gst_object_get_type, "GstBus", c.GstBusClass, Bus, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.dispose = dispose;
    gc.finalize = finalize;
    gc.set_property = setProperty;
    gc.constructed = constructed;
    c.g_object_class_install_property(gc, PROP_ENABLE_ASYNC, c.g_param_spec_boolean("enable-async", "Enable Async", "Enable async message delivery for bus watches and gst_bus_pop()", 1, c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const none: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    sync_signal = c.g_signal_new("sync-message", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_DETAILED, @offsetOf(c.GstBusClass, "sync_message"), null, null, null, none, @as(c.guint, 1), message.gst_message_get_type());
    async_signal = c.g_signal_new("message", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_DETAILED, @offsetOf(c.GstBusClass, "message"), null, null, null, none, @as(c.guint, 1), message.gst_message_get_type());
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Bus = @ptrCast(@alignCast(instance));
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    d.enable_async = 1;
    c.g_mutex_init(&d.queue_lock);
    d.queue = c.gst_vec_deque_new(32);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_ENABLE_ASYNC) priv(o).enable_async = c.g_value_get_boolean(v) else object.warnBadProperty(o, id, pspec);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    if (d.enable_async != 0) {
        d.poll = c.gst_poll_new_timer();
        c.gst_poll_get_read_gpollfd(d.poll, &d.pollfd);
    }
    if (parent_class.?.constructed) |f| f(o);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    if (d.queue != null) {
        c.g_mutex_lock(&d.queue_lock);
        while (c.gst_vec_deque_pop_head(d.queue)) |m| c.gst_mini_object_unref(@ptrCast(@alignCast(m)));
        c.gst_vec_deque_free(d.queue);
        d.queue = null;
        c.g_mutex_unlock(&d.queue_lock);
        c.g_mutex_clear(&d.queue_lock);
        if (d.poll != null) c.gst_poll_free(d.poll);
        d.poll = null;
    }
    parent_class.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const d = priv(o);
    if (d.handler) |h| {
        d.handler = null;
        handlerUnref(h);
    }
    parent_class.?.finalize.?(o);
}

pub export fn gst_bus_new() [*c]Bus {
    const o = c.g_object_new(gst_bus_get_type(), @as([*c]const u8, null));
    _ = object.gst_object_ref_sink(o);
    return @ptrCast(@alignCast(o));
}

fn flushing(p: [*c]Bus) bool {
    return p[0].object.flags & c.GST_BUS_FLUSHING != 0;
}

pub export fn gst_bus_post(p: [*c]Bus, msg: [*c]Message) c.gboolean {
    if (!check.that(isBus(p), "gst_bus_post", "GST_IS_BUS (bus)")) return 0;
    if (!check.that(message.isMessage(msg), "gst_bus_post", "GST_IS_MESSAGE (message)")) return 0;
    const d = priv(p);
    object.lock(p);
    if (flushing(p)) {
        object.unlock(p);
        c.gst_mini_object_unref(@ptrCast(msg));
        return 0;
    }
    const handler: ?*Handler = if (d.handler) |h| handlerRef(h) else null;
    const emit = d.sync_emitters > 0;
    object.unlock(p);
    var reply: c.GstBusSyncReply = c.GST_BUS_PASS;
    if (handler) |h| reply = h.func.?(p, msg, h.data);
    const own = if (handler) |h| h.func == gst_bus_sync_signal_handler else false;
    if (emit and reply != c.GST_BUS_DROP and !own) _ = gst_bus_sync_signal_handler(p, msg, null);
    if (handler) |h| handlerUnref(h);
    if (d.poll == null and reply != c.GST_BUS_DROP) {
        reply = c.GST_BUS_DROP;
        c.gst_mini_object_unref(@ptrCast(msg));
    }
    switch (reply) {
        c.GST_BUS_DROP => {},
        c.GST_BUS_PASS => {
            c.g_mutex_lock(&d.queue_lock);
            c.gst_vec_deque_push_tail(d.queue, msg);
            _ = c.gst_poll_write_control(d.poll);
            c.g_mutex_unlock(&d.queue_lock);
        },
        c.GST_BUS_ASYNC => {
            c.g_cond_init(&msg[0].cond);
            c.g_mutex_init(&msg[0].lock);
            msg[0].mini_object.flags |= ASYNC_DELIVERY;
            c.g_mutex_lock(&msg[0].lock);
            c.g_mutex_lock(&d.queue_lock);
            c.gst_vec_deque_push_tail(d.queue, msg);
            _ = c.gst_poll_write_control(d.poll);
            c.g_mutex_unlock(&d.queue_lock);
            c.g_cond_wait(&msg[0].cond, &msg[0].lock);
            c.g_mutex_unlock(&msg[0].lock);
            msg[0].mini_object.flags &= ~ASYNC_DELIVERY;
            c.g_mutex_clear(&msg[0].lock);
            c.g_cond_clear(&msg[0].cond);
            c.gst_mini_object_unref(@ptrCast(msg));
        },
        else => {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "invalid return from bus sync handler");
            c.gst_mini_object_unref(@ptrCast(msg));
        },
    }
    return 1;
}

pub export fn gst_bus_have_pending(p: [*c]Bus) c.gboolean {
    if (!check.that(isBus(p), "gst_bus_have_pending", "GST_IS_BUS (bus)")) return 0;
    const d = priv(p);
    c.g_mutex_lock(&d.queue_lock);
    defer c.g_mutex_unlock(&d.queue_lock);
    return @intFromBool(c.gst_vec_deque_get_length(d.queue) != 0);
}

fn unrefMessage(m: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(m)));
}

pub export fn gst_bus_set_flushing(p: [*c]Bus, on: c.gboolean) void {
    if (!check.that(isBus(p), "gst_bus_set_flushing", "GST_IS_BUS (bus)")) return;
    var list: [*c]c.GList = null;
    object.lock(p);
    if (on != 0) {
        p[0].object.flags |= c.GST_BUS_FLUSHING;
        while (true) {
            const m = gst_bus_pop(p);
            if (m == null) break;
            list = c.g_list_prepend(list, m);
        }
    } else p[0].object.flags &= ~@as(c.guint32, c.GST_BUS_FLUSHING);
    object.unlock(p);
    c.g_list_free_full(list, unrefMessage);
}

fn wanted(m: [*c]Message, types: c.GstMessageType) bool {
    const t = m[0].type;
    if (t & types == 0) return false;
    return t & c.GST_MESSAGE_EXTENDED == 0 or types & c.GST_MESSAGE_EXTENDED != 0;
}

pub export fn gst_bus_timed_pop_filtered(p: [*c]Bus, timeout: c.GstClockTime, types: c.GstMessageType) [*c]Message {
    const f = "gst_bus_timed_pop_filtered";
    if (!check.that(isBus(p), f, "GST_IS_BUS (bus)")) return null;
    if (!check.that(types != 0, f, "types != 0")) return null;
    const d = priv(p);
    if (!check.that(timeout == 0 or d.poll != null, f, "timeout == 0 || bus->priv->poll != NULL")) return null;
    var first = true;
    var then: i64 = 0;
    var elapsed: u64 = 0;
    c.g_mutex_lock(&d.queue_lock);
    defer c.g_mutex_unlock(&d.queue_lock);
    while (true) {
        while (c.gst_vec_deque_pop_head(d.queue)) |raw| {
            const m: [*c]Message = @ptrCast(@alignCast(raw));
            if (d.poll != null) {
                while (c.gst_poll_read_control(d.poll) == 0) {
                    if (std.c._errno().* != @intFromEnum(std.os.linux.E.AGAIN)) break;
                    c.g_thread_yield();
                }
            }
            if (wanted(m, types)) return m;
            c.gst_mini_object_unref(@ptrCast(m));
        }
        if (timeout == 0) return null;
        if (timeout != NONE) {
            if (first) {
                then = c.g_get_monotonic_time();
                first = false;
            } else {
                elapsed = @as(u64, @intCast(c.g_get_monotonic_time() - then)) * 1000;
                if (elapsed > timeout) return null;
            }
        }
        c.g_mutex_unlock(&d.queue_lock);
        const r = c.gst_poll_wait(d.poll, if (timeout == NONE) NONE else timeout - elapsed);
        c.g_mutex_lock(&d.queue_lock);
        if (r == 0) return null;
    }
}

pub export fn gst_bus_timed_pop(p: [*c]Bus, timeout: c.GstClockTime) [*c]Message {
    if (!check.that(isBus(p), "gst_bus_timed_pop", "GST_IS_BUS (bus)")) return null;
    return gst_bus_timed_pop_filtered(p, timeout, c.GST_MESSAGE_ANY);
}

pub export fn gst_bus_pop_filtered(p: [*c]Bus, types: c.GstMessageType) [*c]Message {
    if (!check.that(isBus(p), "gst_bus_pop_filtered", "GST_IS_BUS (bus)")) return null;
    if (!check.that(types != 0, "gst_bus_pop_filtered", "types != 0")) return null;
    return gst_bus_timed_pop_filtered(p, 0, types);
}

pub export fn gst_bus_pop(p: [*c]Bus) [*c]Message {
    if (!check.that(isBus(p), "gst_bus_pop", "GST_IS_BUS (bus)")) return null;
    return gst_bus_timed_pop_filtered(p, 0, c.GST_MESSAGE_ANY);
}

pub export fn gst_bus_peek(p: [*c]Bus) [*c]Message {
    if (!check.that(isBus(p), "gst_bus_peek", "GST_IS_BUS (bus)")) return null;
    const d = priv(p);
    c.g_mutex_lock(&d.queue_lock);
    defer c.g_mutex_unlock(&d.queue_lock);
    const m: [*c]Message = @ptrCast(@alignCast(c.gst_vec_deque_peek_head(d.queue)));
    if (m != null) _ = c.gst_mini_object_ref(@ptrCast(m));
    return m;
}

pub export fn gst_bus_set_sync_handler(p: [*c]Bus, func: c.GstBusSyncHandler, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isBus(p), "gst_bus_set_sync_handler", "GST_IS_BUS (bus)")) return;
    var fresh: ?*Handler = null;
    if (func != null) {
        fresh = std.heap.c_allocator.create(Handler) catch @panic("out of memory");
        fresh.?.* = .{ .func = func, .data = data, .notify = notify, .refs = 1 };
    }
    const d = priv(p);
    object.lock(p);
    const old = d.handler;
    d.handler = fresh;
    object.unlock(p);
    if (old) |h| handlerUnref(h);
}

pub export fn gst_bus_get_pollfd(p: [*c]Bus, fd: [*c]c.GPollFD) void {
    if (!check.that(isBus(p), "gst_bus_get_pollfd", "GST_IS_BUS (bus)")) return;
    if (!check.that(priv(p).poll != null, "gst_bus_get_pollfd", "bus->priv->poll != NULL")) return;
    fd[0] = priv(p).pollfd;
}

fn sourceCheck(s: [*c]c.GSource) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    return @intFromBool(priv(src.bus).pollfd.revents & (c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR) != 0);
}

fn sourceDispatch(s: [*c]c.GSource, callback: c.GSourceFunc, data: c.gpointer) callconv(.c) c.gboolean {
    const src: *Source = @ptrCast(@alignCast(s));
    const p = src.bus;
    if (!check.that(isBus(p), "gst_bus_source_dispatch", "GST_IS_BUS (bus)")) return 0;
    const m = gst_bus_pop(p);
    if (m == null) return 1;
    defer c.gst_mini_object_unref(@ptrCast(m));
    const cb = callback orelse {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "GstBus watch dispatched without callback\nYou must call g_source_set_callback().");
        return 0;
    };
    const handler: c.GstBusFunc = @ptrCast(cb);
    return handler.?(p, m, data);
}

fn sourceDispose(s: [*c]c.GSource) callconv(.c) void {
    const src: *Source = @ptrCast(@alignCast(s));
    object.lock(src.bus);
    if (priv(src.bus).source == s) priv(src.bus).source = null;
    object.unlock(src.bus);
}

fn sourceFinalize(s: [*c]c.GSource) callconv(.c) void {
    const src: *Source = @ptrCast(@alignCast(s));
    if (src.bus != null) c.gst_object_unref(src.bus);
    src.bus = null;
}

fn createWatch(p: [*c]Bus) [*c]c.GSource {
    const d = priv(p);
    if (d.source != null) {
        log(p, "gst_bus_create_watch_unlocked", "Tried to add new GSource while one was already there");
        return null;
    }
    const s = c.g_source_new(&source_funcs, @sizeOf(Source));
    d.source = s;
    c.g_source_set_name(s, "GStreamer message bus watch");
    c.g_source_set_dispose_function(s, sourceDispose);
    const src: *Source = @ptrCast(@alignCast(s));
    src.bus = @ptrCast(@alignCast(c.gst_object_ref(p)));
    c.g_source_add_poll(s, &d.pollfd);
    return s;
}

pub export fn gst_bus_create_watch(p: [*c]Bus) [*c]c.GSource {
    if (!check.that(isBus(p), "gst_bus_create_watch", "GST_IS_BUS (bus)")) return null;
    if (!check.that(priv(p).poll != null, "gst_bus_create_watch", "bus->priv->poll != NULL")) return null;
    object.lock(p);
    defer object.unlock(p);
    return createWatch(p);
}

fn addWatch(p: [*c]Bus, priority: c.gint, func: c.GstBusFunc, data: c.gpointer, notify: c.GDestroyNotify) c.guint {
    const d = priv(p);
    if (d.source != null) {
        log(p, "gst_bus_add_watch_full_unlocked", "Tried to add new watch while one was already there");
        return 0;
    }
    const s = createWatch(p);
    if (s == null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Creating bus watch failed");
        return 0;
    }
    if (priority != c.G_PRIORITY_DEFAULT) c.g_source_set_priority(s, priority);
    c.g_source_set_callback(s, @ptrCast(func), data, notify);
    const id = c.g_source_attach(s, c.g_main_context_get_thread_default());
    c.g_source_unref(s);
    if (id != 0) d.source = s;
    return id;
}

pub export fn gst_bus_add_watch_full(p: [*c]Bus, priority: c.gint, func: c.GstBusFunc, data: c.gpointer, notify: c.GDestroyNotify) c.guint {
    if (!check.that(isBus(p), "gst_bus_add_watch_full", "GST_IS_BUS (bus)")) return 0;
    object.lock(p);
    defer object.unlock(p);
    return addWatch(p, priority, func, data, notify);
}

pub export fn gst_bus_add_watch(p: [*c]Bus, func: c.GstBusFunc, data: c.gpointer) c.guint {
    return gst_bus_add_watch_full(p, c.G_PRIORITY_DEFAULT, func, data, null);
}

pub export fn gst_bus_remove_watch(p: [*c]Bus) c.gboolean {
    if (!check.that(isBus(p), "gst_bus_remove_watch", "GST_IS_BUS (bus)")) return 0;
    const d = priv(p);
    object.lock(p);
    if (d.source == null) {
        log(p, "gst_bus_remove_watch", "no bus watch was present");
        object.unlock(p);
        return 0;
    }
    if (d.signal_watchers > 0) {
        log(p, "gst_bus_remove_watch", "trying to remove signal watch with gst_bus_remove_watch()");
        object.unlock(p);
        return 0;
    }
    const s = c.g_source_ref(d.source);
    d.source = null;
    object.unlock(p);
    c.g_source_destroy(s);
    c.g_source_unref(s);
    return 1;
}

const PollData = struct {
    loop: ?*c.GMainLoop,
    timeout_id: c.guint,
    running: bool,
    events: c.GstMessageType,
    msg: [*c]Message,
};

fn pollMessage(_: [*c]Bus, m: [*c]Message, data: c.gpointer) callconv(.c) void {
    const pd: *PollData = @ptrCast(@alignCast(data));
    if (c.g_main_loop_is_running(pd.loop) == 0) return;
    if (m[0].type & pd.events == 0) return;
    pd.msg = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(m))));
    c.g_main_loop_quit(pd.loop);
}

fn pollTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_main_loop_quit(@as(*PollData, @ptrCast(@alignCast(data))).loop);
    return 1;
}

fn pollFree(pd: *PollData) void {
    c.g_main_loop_unref(pd.loop);
    std.heap.c_allocator.destroy(pd);
}

fn pollDestroy(data: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
    const pd: *PollData = @ptrCast(@alignCast(data));
    pd.running = false;
    if (pd.timeout_id == 0) pollFree(pd);
}

fn pollDestroyTimeout(data: c.gpointer) callconv(.c) void {
    const pd: *PollData = @ptrCast(@alignCast(data));
    pd.timeout_id = 0;
    if (!pd.running) pollFree(pd);
}

pub export fn gst_bus_poll(p: [*c]Bus, events: c.GstMessageType, timeout: c.GstClockTime) [*c]Message {
    if (!check.that(isBus(p), "gst_bus_poll", "GST_IS_BUS (bus)")) return null;
    const pd = std.heap.c_allocator.create(PollData) catch return null;
    pd.* = .{ .loop = c.g_main_loop_new(null, 0), .timeout_id = 0, .running = true, .events = events, .msg = null };
    if (timeout != NONE) pd.timeout_id = c.g_timeout_add_full(c.G_PRIORITY_DEFAULT_IDLE, @intCast(timeout / 1000000), pollTimeout, pd, pollDestroyTimeout);
    const id = c.g_signal_connect_data(p, "message", @ptrCast(&pollMessage), pd, pollDestroy, 0);
    gst_bus_add_signal_watch(p);
    c.g_main_loop_run(pd.loop);
    gst_bus_remove_signal_watch(p);
    const r = pd.msg;
    if (pd.timeout_id != 0) _ = c.g_source_remove(pd.timeout_id);
    c.g_signal_handler_disconnect(p, id);
    return r;
}

pub export fn gst_bus_async_signal_func(p: [*c]Bus, m: [*c]Message, _: c.gpointer) c.gboolean {
    if (!check.that(isBus(p), "gst_bus_async_signal_func", "GST_IS_BUS (bus)")) return 1;
    if (!check.that(m != null, "gst_bus_async_signal_func", "message != NULL")) return 1;
    c.g_signal_emit(p, async_signal, message.gst_message_type_to_quark(m[0].type), m);
    return 1;
}

pub export fn gst_bus_sync_signal_handler(p: [*c]Bus, m: [*c]Message, _: c.gpointer) c.GstBusSyncReply {
    if (!check.that(isBus(p), "gst_bus_sync_signal_handler", "GST_IS_BUS (bus)")) return c.GST_BUS_DROP;
    if (!check.that(m != null, "gst_bus_sync_signal_handler", "message != NULL")) return c.GST_BUS_DROP;
    c.g_signal_emit(p, sync_signal, message.gst_message_type_to_quark(m[0].type), m);
    return c.GST_BUS_PASS;
}

pub export fn gst_bus_enable_sync_message_emission(p: [*c]Bus) void {
    if (!check.that(isBus(p), "gst_bus_enable_sync_message_emission", "GST_IS_BUS (bus)")) return;
    object.lock(p);
    priv(p).sync_emitters += 1;
    object.unlock(p);
}

pub export fn gst_bus_disable_sync_message_emission(p: [*c]Bus) void {
    if (!check.that(isBus(p), "gst_bus_disable_sync_message_emission", "GST_IS_BUS (bus)")) return;
    if (!check.that(priv(p).sync_emitters > 0, "gst_bus_disable_sync_message_emission", "bus->priv->num_sync_message_emitters > 0")) return;
    object.lock(p);
    priv(p).sync_emitters -= 1;
    object.unlock(p);
}

pub export fn gst_bus_add_signal_watch_full(p: [*c]Bus, priority: c.gint) void {
    if (!check.that(isBus(p), "gst_bus_add_signal_watch_full", "GST_IS_BUS (bus)")) return;
    const d = priv(p);
    object.lock(p);
    defer object.unlock(p);
    if (d.signal_watchers == 0) {
        if (d.source != null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Bus %s already has a GSource watch", p[0].object.name);
            return;
        }
        _ = addWatch(p, priority, gst_bus_async_signal_func, null, null);
        if (d.source == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Could not add signal watch to bus %s", p[0].object.name);
            return;
        }
    }
    d.signal_watchers += 1;
}

pub export fn gst_bus_add_signal_watch(p: [*c]Bus) void {
    gst_bus_add_signal_watch_full(p, c.G_PRIORITY_DEFAULT);
}

pub export fn gst_bus_remove_signal_watch(p: [*c]Bus) void {
    if (!check.that(isBus(p), "gst_bus_remove_signal_watch", "GST_IS_BUS (bus)")) return;
    const d = priv(p);
    object.lock(p);
    if (d.signal_watchers == 0) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Bus %s has no signal watches attached", p[0].object.name);
        object.unlock(p);
        return;
    }
    d.signal_watchers -= 1;
    var s: [*c]c.GSource = null;
    if (d.signal_watchers == 0) {
        s = c.g_source_ref(d.source);
        d.source = null;
    }
    object.unlock(p);
    if (s != null) {
        c.g_source_destroy(s);
        c.g_source_unref(s);
    }
}
