const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const tracer = @import("tracer.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const pad = @import("pad.zig");
const padflow = @import("padflow.zig");
const element = @import("element.zig");
const childproxy = @import("childproxy.zig");
const va = @import("varargs.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Bin = c.GstBin;
const Class = c.GstBinClass;
const Element = c.GstElement;
const Msg = c.GstMessage;
const Obj = c.GstObject;
const NONE: u64 = std.math.maxInt(u64);
const NONE_TYPE: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;

const Private = extern struct {
    asynchandling: c.gboolean,
    pending_async_done: c.gboolean,
    structure_cookie: c.guint32,
    message_forward: c.gboolean,
    posted_eos: c.gint,
    posted_playing: c.gboolean,
    suppressed_flags: c.GstElementFlags,
};

const Continue = struct { cookie: c.guint32, pending: c.GstState };

const PROP_ASYNC_HANDLING = 1;
const PROP_MESSAGE_FORWARD = 2;

var private_offset: c.gint = 0;
var parent_class: ?*c.GstElementClass = null;
var type_once: gtype.Once = .{};
var debug_cat: [*c]c.GstDebugCategory = null;
var sig_added: c.guint = 0;
var sig_removed: c.guint = 0;
var sig_latency: c.guint = 0;
var sig_deep_added: c.guint = 0;
var sig_deep_removed: c.guint = 0;

fn priv(b: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(b));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

pub fn isBin(p: anytype) bool {
    return gtype.instanceOf(p, gst_bin_get_type());
}

fn el(b: anytype) [*c]Element {
    return @ptrCast(@alignCast(b));
}

fn classOf(b: anytype) *Class {
    return gtype.classPeek(Class, b);
}

fn lock(b: anytype) void {
    object.lock(b);
}

fn unlock(b: anytype) void {
    object.unlock(b);
}

fn flags(o: anytype) *c.guint32 {
    return @ptrCast(&@as([*c]Obj, @ptrCast(@alignCast(o)))[0].flags);
}

fn has(o: anytype, f: c.guint) bool {
    return flags(o).* & f != 0;
}

fn parentOf(o: anytype) [*c]Obj {
    return @as([*c]Obj, @ptrCast(@alignCast(o)))[0].parent;
}

fn toplevel(b: [*c]Bin) bool {
    return parentOf(b) == null or priv(b).asynchandling != 0;
}

fn noResync(b: [*c]Bin) bool {
    return has(b, c.GST_BIN_FLAG_NO_RESYNC);
}

fn stateLock(e: [*c]Element) void {
    c.g_rec_mutex_lock(@ptrCast(&e[0].state_lock));
}

fn stateUnlock(e: [*c]Element) void {
    c.g_rec_mutex_unlock(@ptrCast(&e[0].state_lock));
}

fn nextState(cur: c.GstState, pending: c.GstState) c.GstState {
    const d: c_int = @as(c_int, @intCast(pending)) - @as(c_int, @intCast(cur));
    const step: c_int = if (d > 0) 1 else if (d < 0) -1 else 0;
    return @intCast(@as(c_int, @intCast(cur)) + step);
}

pub export fn gst_bin_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(element.gst_element_get_type(), "GstBin", Class, Bin, classInit, instanceInit, 0);
            private_offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            const iface = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, childproxy.gst_child_proxy_get_type(), &iface);
            debug_cat = info._gst_debug_category_new("bin", c.GST_DEBUG_BOLD, "debugging info for the 'bin' container element");
            return t;
        }
    }.f);
}

fn proxyByIndex(p: ?*c.GstChildProxy, idx: c.guint) callconv(.c) [*c]c.GObject {
    const b: [*c]Bin = @ptrCast(@alignCast(p));
    lock(b);
    defer unlock(b);
    const r = c.g_list_nth_data(b[0].children, idx);
    if (r != null) _ = c.gst_object_ref(r);
    return @ptrCast(@alignCast(r));
}

fn proxyCount(p: ?*c.GstChildProxy) callconv(.c) c.guint {
    const b: [*c]Bin = @ptrCast(@alignCast(p));
    lock(b);
    defer unlock(b);
    return @intCast(b[0].numchildren);
}

fn proxyInit(g_iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(g_iface));
    i.get_children_count = proxyCount;
    i.get_child_by_index = proxyByIndex;
}

fn boolAccumulator(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    c.g_value_set_boolean(accu, c.g_value_get_boolean(ret));
    return 0;
}

fn classInit(klass: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(klass, &private_offset);
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(klass)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(klass));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    const fl = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, PROP_ASYNC_HANDLING, c.g_param_spec_boolean("async-handling", "Async Handling", "The bin will handle Asynchronous state changes", 0, fl));
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const et = element.gst_element_get_type();
    sig_added = c.g_signal_new("element-added", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "element_added"), null, null, null, NONE_TYPE, @as(c.guint, 1), et);
    sig_removed = c.g_signal_new("element-removed", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "element_removed"), null, null, null, NONE_TYPE, @as(c.guint, 1), et);
    sig_deep_added = c.g_signal_new("deep-element-added", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "deep_element_added"), null, null, null, NONE_TYPE, @as(c.guint, 2), t, et);
    sig_deep_removed = c.g_signal_new("deep-element-removed", t, c.G_SIGNAL_RUN_FIRST, @offsetOf(Class, "deep_element_removed"), null, null, null, NONE_TYPE, @as(c.guint, 2), t, et);
    sig_latency = c.g_signal_new("do-latency", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "do_latency"), boolAccumulator, null, null, @as(c.GType, c.G_TYPE_BOOLEAN), @as(c.guint, 0), NONE_TYPE);
    c.g_object_class_install_property(gc, PROP_MESSAGE_FORWARD, c.g_param_spec_boolean("message-forward", "Message Forward", "Forwards all children messages", 0, fl));
    gc.dispose = dispose;
    const ek: [*c]c.GstElementClass = @ptrCast(@alignCast(klass));
    element.gst_element_class_set_static_metadata(ek, "Generic bin", "Generic/Bin", "Simple container object", "Erik Walthinsen <omega@cse.ogi.edu>,Wim Taymans <wim.taymans@gmail.com>");
    ek[0].change_state = changeState;
    ek[0].post_message = postMessage;
    ek[0].get_state = getState;
    ek[0].provide_clock = provideClock;
    ek[0].set_clock = setClock;
    ek[0].send_event = sendEvent;
    ek[0].query = query;
    ek[0].set_context = setContext;
    const k: *Class = @ptrCast(@alignCast(klass));
    k.add_element = addFunc;
    k.remove_element = removeFunc;
    k.handle_message = handleMessage;
    k.deep_element_added = deepAdded;
    k.deep_element_removed = deepRemoved;
    k.do_latency = doLatency;
    inline for (.{ .{ &changeState, "gst_bin_change_state_func" }, .{ &postMessage, "gst_bin_post_message" }, .{ &getState, "gst_bin_get_state_func" }, .{ &provideClock, "gst_bin_provide_clock_func" }, .{ &setClock, "gst_bin_set_clock_func" }, .{ &sendEvent, "gst_bin_send_event" }, .{ &query, "gst_bin_query" }, .{ &setContext, "gst_bin_set_context" }, .{ &addFunc, "gst_bin_add_func" }, .{ &removeFunc, "gst_bin_remove_func" }, .{ &handleMessage, "gst_bin_handle_message_func" }, .{ &doLatency, "gst_bin_do_latency_func" } }) |pair|
        info._gst_debug_register_funcptr(@ptrCast(pair[0]), pair[1]);
}

fn busHandler(_: [*c]c.GstBus, m: [*c]Msg, data: c.gpointer) callconv(.c) c.GstBusSyncReply {
    const b: [*c]Bin = @ptrCast(@alignCast(data));
    if (classOf(b).handle_message) |f| f(b, m) else c.gst_mini_object_unref(@ptrCast(m));
    return c.GST_BUS_DROP;
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const b: [*c]Bin = @ptrCast(@alignCast(instance));
    b[0].numchildren = 0;
    b[0].children = null;
    b[0].children_cookie = 0;
    b[0].messages = null;
    b[0].provided_clock = null;
    b[0].clock_dirty = 0;
    const bus = c.g_object_new(c.gst_bus_get_type(), "enable-async", @as(c.gboolean, 0), @as([*c]const u8, null));
    _ = object.gst_object_ref_sink(bus);
    b[0].child_bus = @ptrCast(@alignCast(bus));
    c.gst_bus_set_sync_handler(b[0].child_bus, busHandler, b, null);
    b[0].priv = @ptrCast(priv(b));
    priv(b).asynchandling = 0;
    priv(b).structure_cookie = 0;
    priv(b).message_forward = 0;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const b: [*c]Bin = @ptrCast(@alignCast(o));
    lock(b);
    _ = object.gst_object_replace(@ptrCast(&b[0].child_bus), null);
    _ = object.gst_object_replace(@ptrCast(&b[0].provided_clock), null);
    _ = object.gst_object_replace(@ptrCast(&b[0].clock_provider), null);
    removeMessages(b, null, c.GST_MESSAGE_ANY);
    unlock(b);
    while (b[0].children != null) _ = gst_bin_remove(b, @ptrCast(@alignCast(b[0].children[0].data)));
    if (b[0].children != null) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "could not remove elements from bin '%s'", pad.nameOf(@ptrCast(b)));
    @as(*c.GObjectClass, @ptrCast(parent_class.?)).dispose.?(o);
}

pub export fn gst_bin_new(name: [*c]const u8) [*c]Element {
    const r = @import("elementfactory.zig").gst_element_factory_make("bin", name);
    if (r != null) return r;
    return @ptrCast(@alignCast(c.g_object_new(gst_bin_get_type(), "name", name, @as([*c]const u8, null))));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    lock(o);
    defer unlock(o);
    switch (id) {
        PROP_ASYNC_HANDLING => priv(o).asynchandling = c.g_value_get_boolean(v),
        PROP_MESSAGE_FORWARD => priv(o).message_forward = c.g_value_get_boolean(v),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    lock(o);
    defer unlock(o);
    switch (id) {
        PROP_ASYNC_HANDLING => c.g_value_set_boolean(v, priv(o).asynchandling),
        PROP_MESSAGE_FORWARD => c.g_value_set_boolean(v, priv(o).message_forward),
        else => object.warnBadProperty(o, id, pspec),
    }
}

const Walk = struct {
    it: [*c]c.GstIterator,
    item: c.GValue = std.mem.zeroes(c.GValue),

    fn next(self: *Walk) ?c.gpointer {
        while (true) {
            switch (c.gst_iterator_next(self.it, &self.item)) {
                c.GST_ITERATOR_OK => return c.g_value_get_object(&self.item),
                c.GST_ITERATOR_RESYNC => {
                    c.gst_iterator_resync(self.it);
                    return null;
                },
                else => return null,
            }
        }
    }
};

fn eachChild(it: [*c]c.GstIterator, ctx: anytype, comptime func: fn (@TypeOf(ctx), c.gpointer) void, comptime on_resync: ?fn (@TypeOf(ctx)) void) void {
    var item = std.mem.zeroes(c.GValue);
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                func(ctx, c.g_value_get_object(&item));
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                if (on_resync) |r| r(ctx);
            },
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
}

const ClockSet = struct { clock: [*c]c.GstClock, res: c.gboolean };

fn setChildClock(s: *ClockSet, child: c.gpointer) void {
    s.res &= element.gst_element_set_clock(@ptrCast(@alignCast(child)), s.clock);
}

fn resetRes(s: *ClockSet) void {
    s.res = 1;
}

fn setClock(e: [*c]Element, clock: [*c]c.GstClock) callconv(.c) c.gboolean {
    var s = ClockSet{ .clock = clock, .res = 1 };
    eachChild(gst_bin_iterate_elements(@ptrCast(e)), &s, setChildClock, resetRes);
    if (s.res != 0) s.res = parent_class.?.set_clock.?(e, clock);
    return s.res;
}

const ClockFind = struct { result: [*c]c.GstClock = null, provider: [*c]Element = null };

fn findClock(s: *ClockFind, child: c.gpointer) void {
    const clock = element.gst_element_provide_clock(@ptrCast(@alignCast(child)));
    if (clock == null) return;
    if (s.result != null) {
        c.gst_object_unref(s.result);
        c.gst_object_unref(s.provider);
    }
    s.result = clock;
    s.provider = @ptrCast(@alignCast(c.gst_object_ref(child)));
}

fn provideClock(e: [*c]Element) callconv(.c) [*c]c.GstClock {
    const b: [*c]Bin = @ptrCast(@alignCast(e));
    lock(b);
    if (b[0].clock_dirty == 0) return keepClock(b);
    const it = sortIterator(b);
    unlock(b);
    var s = ClockFind{};
    eachChild(it, &s, findClock, null);
    lock(b);
    if (b[0].clock_dirty == 0) {
        if (s.provider != null) c.gst_object_unref(s.provider);
        if (s.result != null) c.gst_object_unref(s.result);
        return keepClock(b);
    }
    _ = object.gst_object_replace(@ptrCast(&b[0].provided_clock), @ptrCast(s.result));
    _ = object.gst_object_replace(@ptrCast(&b[0].clock_provider), @ptrCast(s.provider));
    b[0].clock_dirty = 0;
    if (s.provider != null) c.gst_object_unref(s.provider);
    unlock(b);
    return s.result;
}

fn keepClock(b: [*c]Bin) [*c]c.GstClock {
    const r = b[0].provided_clock;
    if (r != null) _ = c.gst_object_ref(r);
    unlock(b);
    return r;
}

fn matches(m: [*c]Msg, src: [*c]Obj, types: c.GstMessageType) bool {
    if (src != null and m[0].src != src) return false;
    if (types != 0 and m[0].type & types == 0) return false;
    return true;
}

fn findMessage(b: [*c]Bin, src: [*c]Obj, types: c.GstMessageType) [*c]c.GList {
    var l = b[0].messages;
    while (l != null) : (l = l[0].next) if (matches(@ptrCast(@alignCast(l[0].data)), src, types)) return l;
    return null;
}

fn replaceMessage(b: [*c]Bin, m: [*c]Msg, types: c.GstMessageType) void {
    const src = m[0].src;
    if (src == null) {
        c.gst_mini_object_unref(@ptrCast(m));
        return;
    }
    const prev = findMessage(b, src, types);
    if (prev != null) {
        const old: [*c]Msg = @ptrCast(@alignCast(prev[0].data));
        prev[0].data = m;
        c.gst_mini_object_unref(@ptrCast(old));
    } else b[0].messages = c.g_list_prepend(b[0].messages, m);
}

fn removeMessages(b: [*c]Bin, src: [*c]Obj, types: c.GstMessageType) void {
    var l = b[0].messages;
    while (l != null) {
        const nxt = l[0].next;
        const m: [*c]Msg = @ptrCast(@alignCast(l[0].data));
        if (matches(m, src, types)) {
            b[0].messages = c.g_list_delete_link(b[0].messages, l);
            c.gst_mini_object_unref(@ptrCast(m));
        }
        l = nxt;
    }
}

fn isSinkChild(e: anytype) bool {
    lock(e);
    defer unlock(e);
    return has(e, c.GST_ELEMENT_FLAG_SINK);
}

fn isSrcChild(e: anytype) bool {
    lock(e);
    defer unlock(e);
    return has(e, c.GST_ELEMENT_FLAG_SOURCE);
}

fn isEos(b: [*c]Bin, seqnum: *c.guint32) bool {
    var n: usize = 0;
    var l = b[0].children;
    while (l != null) : (l = l[0].next) {
        if (!isSinkChild(l[0].data)) continue;
        const m = findMessage(b, @ptrCast(@alignCast(l[0].data)), c.GST_MESSAGE_EOS);
        if (m == null) return false;
        seqnum.* = c.gst_message_get_seqnum(@ptrCast(@alignCast(m[0].data)));
        n += 1;
    }
    return n > 0;
}

fn isStreamStart(b: [*c]Bin, seqnum: *c.guint32, have_group: *bool, group: *c.guint) bool {
    have_group.* = false;
    group.* = 0;
    var result = false;
    var first = true;
    var first_group = true;
    var same = true;
    var l = b[0].children;
    while (l != null) : (l = l[0].next) {
        if (!isSinkChild(l[0].data)) continue;
        const ml = findMessage(b, @ptrCast(@alignCast(l[0].data)), c.GST_MESSAGE_STREAM_START);
        if (ml == null) {
            result = false;
            break;
        }
        if (first) {
            have_group.* = true;
            result = true;
            first = false;
        }
        const m: [*c]Msg = @ptrCast(@alignCast(ml[0].data));
        seqnum.* = c.gst_message_get_seqnum(m);
        var tmp: c.guint = 0;
        if (c.gst_message_parse_group_id(m, &tmp) != 0) {
            if (first_group) {
                first_group = false;
                group.* = tmp;
            } else if (tmp != group.*) same = false;
        } else have_group.* = false;
    }
    if (have_group.*) return same and result;
    return result;
}

fn unlinkPad(item: [*c]const c.GValue, _: c.gpointer) callconv(.c) void {
    const p: [*c]pad.Pad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    const peer = pad.gst_pad_get_peer(p);
    if (peer == null) return;
    if (pad.gst_pad_get_direction(p) == c.GST_PAD_SRC) _ = pad.gst_pad_unlink(p, peer) else _ = pad.gst_pad_unlink(peer, p);
    c.gst_object_unref(peer);
}

fn unlinkAll(e: [*c]Element) void {
    const it = element.gst_element_iterate_pads(e);
    while (c.gst_iterator_foreach(it, unlinkPad, null) == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(it);
    c.gst_iterator_free(it);
}

fn queuePush(item: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    c.g_queue_push_tail(@ptrCast(@alignCast(data)), c.g_value_dup_object(item));
}

fn unrefData(p: c.gpointer) callconv(.c) void {
    c.gst_object_unref(p);
}

fn deepSignal(b: [*c]Bin, sig: c.guint, e: [*c]Element) void {
    c.g_signal_emit(b, sig, 0, b, e);
    if (!isBin(e)) return;
    const it = gst_bin_iterate_recurse(@ptrCast(@alignCast(e)));
    var q = std.mem.zeroes(c.GQueue);
    var r: c.GstIteratorResult = undefined;
    while (true) {
        r = c.gst_iterator_foreach(it, queuePush, &q);
        if (r != c.GST_ITERATOR_DONE) c.g_queue_clear_full(&q, unrefData);
        if (r != c.GST_ITERATOR_RESYNC) break;
        c.gst_iterator_resync(it);
    }
    if (r != c.GST_ITERATOR_ERROR) {
        while (c.g_queue_pop_head(&q)) |x| {
            const parent = c.gst_object_get_parent(@ptrCast(@alignCast(x)));
            if (parent != null) {
                c.g_signal_emit(b, sig, 0, parent, x);
                c.gst_object_unref(parent);
            }
            c.gst_object_unref(x);
        }
    }
    c.gst_iterator_free(it);
}

fn addFunc(b: [*c]Bin, e: [*c]Element) callconv(.c) c.gboolean {
    lock(e);
    const name = c.g_strdup(@as([*c]Obj, @ptrCast(e))[0].name);
    defer c.g_free(name);
    const is_sink = has(e, c.GST_ELEMENT_FLAG_SINK);
    const is_source = has(e, c.GST_ELEMENT_FLAG_SOURCE);
    const provides = has(e, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    const requires = has(e, c.GST_ELEMENT_FLAG_REQUIRE_CLOCK);
    unlock(e);
    lock(b);
    if (c.gst_object_check_uniqueness(b[0].children, name) == 0) {
        unlock(b);
        _ = object.gst_object_ref_sink(e);
        c.gst_object_unref(e);
        return 0;
    }
    if (c.gst_object_set_parent(@ptrCast(e), @ptrCast(b)) == 0) {
        unlock(b);
        return 0;
    }
    const sup = priv(b).suppressed_flags;
    var clock_msg: [*c]Msg = null;
    var async_msg: [*c]Msg = null;
    if (is_sink and sup & c.GST_ELEMENT_FLAG_SINK == 0) flags(b).* |= c.GST_ELEMENT_FLAG_SINK;
    if (is_source and sup & c.GST_ELEMENT_FLAG_SOURCE == 0) flags(b).* |= c.GST_ELEMENT_FLAG_SOURCE;
    if (provides and sup & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK == 0) {
        clock_msg = c.gst_message_new_clock_provide(@ptrCast(e), null, 1);
        flags(b).* |= c.GST_ELEMENT_FLAG_PROVIDE_CLOCK;
    }
    if (requires and sup & c.GST_ELEMENT_FLAG_REQUIRE_CLOCK == 0) flags(b).* |= c.GST_ELEMENT_FLAG_REQUIRE_CLOCK;
    b[0].children = c.g_list_prepend(b[0].children, e);
    b[0].numchildren += 1;
    b[0].children_cookie +%= 1;
    if (!noResync(b)) priv(b).structure_cookie +%= 1;
    element.gst_element_set_bus(e, b[0].child_bus);
    element.gst_element_set_base_time(e, @bitCast(el(b)[0].base_time));
    element.gst_element_set_start_time(e, el(b)[0].start_time);
    _ = element.gst_element_set_clock(e, el(b)[0].clock);
    const own = element.gst_element_get_contexts(e);
    var l = el(b)[0].contexts;
    while (l != null) : (l = l[0].next) element.gst_element_set_context(e, @ptrCast(l[0].data));
    var need: [*c]c.GList = null;
    l = own;
    while (l != null) : (l = l[0].next) {
        const ctx: ?*c.GstContext = @ptrCast(l[0].data);
        const kind = c.gst_context_get_context_type(ctx);
        const rep = element.gst_element_get_context_unlocked(el(b), kind);
        if (rep != null) {
            c.gst_context_unref(rep);
        } else {
            const m = c.gst_message_new_need_context(@ptrCast(b), kind);
            const s: [*c]c.GstStructure = @constCast(c.gst_message_get_structure(m));
            var v = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&v, c.gst_context_get_type());
            c.g_value_set_boxed(&v, ctx);
            c.gst_structure_take_value(s, "bin.old.context", &v);
            need = c.g_list_prepend(need, m);
        }
    }
    if (el(b)[0].last_return != c.GST_STATE_CHANGE_FAILURE) {
        switch (e[0].last_return) {
            c.GST_STATE_CHANGE_ASYNC => async_msg = c.gst_message_new_async_start(@ptrCast(e)),
            c.GST_STATE_CHANGE_NO_PREROLL => asyncDone(b, e[0].last_return, false, NONE),
            else => {},
        }
    }
    unlock(b);
    l = need;
    while (l != null) : (l = l[0].next) {
        const m: [*c]Msg = @ptrCast(@alignCast(l[0].data));
        var kind: [*c]const u8 = null;
        _ = c.gst_message_parse_context_type(m, &kind);
        const s: [*c]c.GstStructure = @constCast(c.gst_message_get_structure(m));
        var ctx: ?*c.GstContext = null;
        _ = c.gst_structure_get(s, "bin.old.context", c.gst_context_get_type(), &ctx, @as(?*anyopaque, null));
        c.gst_structure_remove_field(s, "bin.old.context");
        _ = element.gst_element_post_message(el(b), @ptrCast(c.gst_mini_object_ref(@ptrCast(m))));
        lock(b);
        const rep = element.gst_element_get_context_unlocked(el(b), kind);
        c.gst_mini_object_unref(@ptrCast(m));
        if (rep != null) {
            c.gst_context_unref(rep);
            unlock(b);
        } else {
            updateContextUnlocked(b, ctx);
            const hm = c.gst_message_new_have_context(@ptrCast(b), c.gst_context_ref(ctx));
            unlock(b);
            _ = element.gst_element_post_message(el(b), hm);
        }
        c.gst_context_unref(ctx);
    }
    c.g_list_free_full(own, unrefContext);
    c.g_list_free(need);
    if (clock_msg != null) _ = element.gst_element_post_message(e, clock_msg);
    if (async_msg != null) _ = element.gst_element_post_message(e, async_msg);
    unlinkAll(e);
    c.g_signal_emit(b, sig_added, 0, e);
    childproxy.gst_child_proxy_child_added(@ptrCast(b), @ptrCast(e), name);
    deepSignal(b, sig_deep_added, e);
    return 1;
}

fn unrefContext(p: c.gpointer) callconv(.c) void {
    c.gst_context_unref(@ptrCast(p));
}

pub export fn gst_bin_set_suppressed_flags(b: [*c]Bin, f: c.GstElementFlags) void {
    if (!check.that(isBin(b), "gst_bin_set_suppressed_flags", "GST_IS_BIN (bin)")) return;
    lock(b);
    priv(b).suppressed_flags |= f;
    unlock(b);
}

pub export fn gst_bin_get_suppressed_flags(b: [*c]Bin) c.GstElementFlags {
    if (!check.that(isBin(b), "gst_bin_get_suppressed_flags", "GST_IS_BIN (bin)")) return 0;
    lock(b);
    defer unlock(b);
    return priv(b).suppressed_flags;
}

fn deepAdded(b: [*c]Bin, sub: [*c]Bin, child: [*c]Element) callconv(.c) void {
    const parent = c.gst_object_get_parent(@ptrCast(b));
    if (parent == null) return;
    c.g_signal_emit(parent, sig_deep_added, 0, sub, child);
    c.gst_object_unref(parent);
}

fn deepRemoved(b: [*c]Bin, sub: [*c]Bin, child: [*c]Element) callconv(.c) void {
    const parent = c.gst_object_get_parent(@ptrCast(b));
    if (parent == null) return;
    c.g_signal_emit(parent, sig_deep_removed, 0, sub, child);
    c.gst_object_unref(parent);
}

pub export fn gst_bin_add(b: [*c]Bin, e: [*c]Element) c.gboolean {
    const f = "gst_bin_add";
    if (!check.that(isBin(b), f, "GST_IS_BIN (bin)")) return 0;
    if (!check.that(element.isElement(e), f, "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(el(b) != e, f, "GST_ELEMENT_CAST (bin) != element")) return 0;
    const add = classOf(b).add_element orelse {
        _ = object.gst_object_ref_sink(e);
        c.gst_object_unref(e);
        return 0;
    };
    tracer.emit(.bin_add_pre, .{ b, e });
    const r = add(b, e);
    tracer.emit(.bin_add_post, .{ b, e, r });
    return r;
}

fn removeFunc(b: [*c]Bin, e: [*c]Element) callconv(.c) c.gboolean {
    lock(b);
    lock(e);
    const name = c.g_strdup(@as([*c]Obj, @ptrCast(e))[0].name);
    defer c.g_free(name);
    if (parentOf(e) != @as([*c]Obj, @ptrCast(b))) {
        unlock(e);
        unlock(b);
        return 0;
    }
    @as([*c]Obj, @ptrCast(e))[0].parent = null;
    const is_sink = has(e, c.GST_ELEMENT_FLAG_SINK);
    const is_source = has(e, c.GST_ELEMENT_FLAG_SOURCE);
    const provides = has(e, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    const requires = has(e, c.GST_ELEMENT_FLAG_REQUIRE_CLOCK);
    unlock(e);
    var found = false;
    var other_sink = false;
    var other_src = false;
    var other_prov = false;
    var other_req = false;
    var no_preroll = false;
    var w = b[0].children;
    while (w != null) {
        const nxt = w[0].next;
        const child: [*c]Element = @ptrCast(@alignCast(w[0].data));
        if (child == e) {
            found = true;
            b[0].children = c.g_list_delete_link(b[0].children, w);
        } else {
            lock(child);
            if (is_sink and has(child, c.GST_ELEMENT_FLAG_SINK)) other_sink = true;
            if (is_source and has(child, c.GST_ELEMENT_FLAG_SOURCE)) other_src = true;
            if (provides and has(child, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK)) other_prov = true;
            if (requires and has(child, c.GST_ELEMENT_FLAG_REQUIRE_CLOCK)) other_req = true;
            if (child[0].last_return == c.GST_STATE_CHANGE_NO_PREROLL) no_preroll = true;
            unlock(child);
        }
        w = nxt;
    }
    if (!found) {
        unlock(b);
        return 0;
    }
    b[0].numchildren -= 1;
    b[0].children_cookie +%= 1;
    if (!noResync(b)) priv(b).structure_cookie +%= 1;
    const sup = priv(b).suppressed_flags;
    const unset = struct {
        fn f(o: anytype, fl: c.guint) void {
            flags(o).* &= ~@as(c.guint32, fl);
        }
    }.f;
    if (is_sink and !other_sink and sup & c.GST_ELEMENT_FLAG_SINK == 0) unset(b, c.GST_ELEMENT_FLAG_SINK);
    if (is_source and !other_src and sup & c.GST_ELEMENT_FLAG_SOURCE == 0) unset(b, c.GST_ELEMENT_FLAG_SOURCE);
    if (provides and !other_prov and sup & c.GST_ELEMENT_FLAG_PROVIDE_CLOCK == 0) unset(b, c.GST_ELEMENT_FLAG_PROVIDE_CLOCK);
    if (requires and !other_req and sup & c.GST_ELEMENT_FLAG_REQUIRE_CLOCK == 0) unset(b, c.GST_ELEMENT_FLAG_REQUIRE_CLOCK);
    var clock_msg: [*c]Msg = null;
    if (b[0].clock_provider == e) {
        b[0].clock_dirty = 1;
        clock_msg = c.gst_message_new_clock_lost(@ptrCast(b), b[0].provided_clock);
        _ = object.gst_object_replace(@ptrCast(&b[0].provided_clock), null);
        _ = object.gst_object_replace(@ptrCast(&b[0].clock_provider), null);
    }
    var this_async = false;
    var other_async = false;
    var removed_eos = false;
    w = b[0].messages;
    while (w != null) {
        const nxt = w[0].next;
        const m: [*c]Msg = @ptrCast(@alignCast(w[0].data));
        const src: [*c]Element = @ptrCast(@alignCast(m[0].src));
        var remove = false;
        switch (m[0].type) {
            c.GST_MESSAGE_ASYNC_START => if (src == e) {
                this_async = true;
            } else {
                other_async = true;
            },
            c.GST_MESSAGE_STRUCTURE_CHANGE => {
                var owner: [*c]Element = null;
                c.gst_message_parse_structure_change(m, null, &owner, null);
                if (owner == e) remove = true;
            },
            c.GST_MESSAGE_EOS => if (src == e) {
                removed_eos = true;
            },
            else => {},
        }
        if (src == e) remove = true;
        if (remove) {
            b[0].messages = c.g_list_delete_link(b[0].messages, w);
            c.gst_mini_object_unref(@ptrCast(m));
        }
        w = nxt;
    }
    if (el(b)[0].last_return != c.GST_STATE_CHANGE_FAILURE) {
        if (!other_async and this_async) {
            asyncDone(b, if (no_preroll) c.GST_STATE_CHANGE_NO_PREROLL else c.GST_STATE_CHANGE_SUCCESS, false, NONE);
        } else {
            var ret = el(b)[0].last_return;
            if (no_preroll) {
                ret = c.GST_STATE_CHANGE_NO_PREROLL;
            } else if (other_async) {
                if (el(b)[0].pending_state == c.GST_STATE_VOID_PENDING) {
                    el(b)[0].next_state = el(b)[0].current_state;
                    el(b)[0].pending_state = el(b)[0].current_state;
                }
                ret = c.GST_STATE_CHANGE_ASYNC;
            }
            el(b)[0].last_return = ret;
        }
    }
    element.gst_element_set_bus(e, null);
    _ = element.gst_element_set_clock(e, null);
    unlock(b);
    if (is_sink and !removed_eos) doEos(b);
    if (clock_msg != null) _ = element.gst_element_post_message(el(b), clock_msg);
    unlinkAll(e);
    c.g_signal_emit(b, sig_removed, 0, e);
    childproxy.gst_child_proxy_child_removed(@ptrCast(b), @ptrCast(e), name);
    deepSignal(b, sig_deep_removed, e);
    c.gst_object_unref(e);
    return 1;
}

pub export fn gst_bin_remove(b: [*c]Bin, e: [*c]Element) c.gboolean {
    const f = "gst_bin_remove";
    if (!check.that(isBin(b), f, "GST_IS_BIN (bin)")) return 0;
    if (!check.that(element.isElement(e), f, "GST_IS_ELEMENT (element)")) return 0;
    if (!check.that(el(b) != e, f, "GST_ELEMENT_CAST (bin) != element")) return 0;
    const rm = classOf(b).remove_element orelse return 0;
    tracer.emit(.bin_remove_pre, .{ b, e });
    const r = rm(b, e);
    tracer.emit(.bin_remove_post, .{ b, r });
    return r;
}

pub export fn gst_bin_add_many(b: [*c]Bin, first: [*c]Element, ...) callconv(.c) void {
    if (!check.that(isBin(b), "gst_bin_add_many", "GST_IS_BIN (bin)")) return;
    if (!check.that(element.isElement(first), "gst_bin_add_many", "GST_IS_ELEMENT (element_1)")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var e = first;
    while (e != null) {
        _ = gst_bin_add(b, e);
        e = @cVaArg(&ap, [*c]Element);
    }
}

pub export fn gst_bin_remove_many(b: [*c]Bin, first: [*c]Element, ...) callconv(.c) void {
    if (!check.that(isBin(b), "gst_bin_remove_many", "GST_IS_BIN (bin)")) return;
    if (!check.that(element.isElement(first), "gst_bin_remove_many", "GST_IS_ELEMENT (element_1)")) return;
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    var e = first;
    while (e != null) {
        _ = gst_bin_remove(b, e);
        e = @cVaArg(&ap, [*c]Element);
    }
}

pub export fn gst_bin_iterate_elements(b: [*c]Bin) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_elements", "GST_IS_BIN (bin)")) return null;
    lock(b);
    defer unlock(b);
    return c.gst_iterator_new_list(element.gst_element_get_type(), @ptrCast(&@as([*c]Obj, @ptrCast(b))[0].lock), &b[0].children_cookie, &b[0].children, @ptrCast(b), null);
}

fn recurseItem(it: [*c]c.GstIterator, item: [*c]const c.GValue) callconv(.c) c.GstIteratorItem {
    const child = c.g_value_get_object(item);
    if (isBin(child)) c.gst_iterator_push(it, gst_bin_iterate_recurse(@ptrCast(@alignCast(child))));
    return c.GST_ITERATOR_ITEM_PASS;
}

pub export fn gst_bin_iterate_recurse(b: [*c]Bin) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_recurse", "GST_IS_BIN (bin)")) return null;
    lock(b);
    defer unlock(b);
    return c.gst_iterator_new_list(element.gst_element_get_type(), @ptrCast(&@as([*c]Obj, @ptrCast(b))[0].lock), &b[0].children_cookie, &b[0].children, @ptrCast(b), recurseItem);
}

fn sinkFilter(a: c.gconstpointer, _: c.gconstpointer) callconv(.c) c.gint {
    return @intFromBool(!isSinkChild(c.g_value_get_object(@ptrCast(@alignCast(a)))));
}

fn srcFilter(a: c.gconstpointer, _: c.gconstpointer) callconv(.c) c.gint {
    return @intFromBool(!isSrcChild(c.g_value_get_object(@ptrCast(@alignCast(a)))));
}

fn filtered(b: [*c]Bin, f: c.GCompareFunc) [*c]c.GstIterator {
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, gst_bin_get_type());
    c.g_value_set_object(&v, b);
    const r = c.gst_iterator_filter(gst_bin_iterate_elements(b), f, &v);
    c.g_value_unset(&v);
    return r;
}

pub export fn gst_bin_iterate_sinks(b: [*c]Bin) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_sinks", "GST_IS_BIN (bin)")) return null;
    return filtered(b, sinkFilter);
}

pub export fn gst_bin_iterate_sources(b: [*c]Bin) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_sources", "GST_IS_BIN (bin)")) return null;
    return filtered(b, srcFilter);
}

fn getState(e: [*c]Element, s: [*c]c.GstState, p: [*c]c.GstState, timeout: c.GstClockTime) callconv(.c) c.GstStateChangeReturn {
    return parent_class.?.get_state.?(e, s, p, timeout);
}

const Sort = extern struct {
    it: c.GstIterator,
    queue: c.GQueue,
    bin: [*c]Bin,
    mode: c.gint,
    best: [*c]Element,
    best_deg: c.gint,
    hash: ?*c.GHashTable,
    dirty: c.gboolean,
};

fn setDeg(s: *Sort, e: anytype, d: c.gint) void {
    _ = c.g_hash_table_replace(s.hash, @ptrCast(@constCast(e)), @ptrFromInt(@as(usize, @bitCast(@as(isize, d + 1)))));
}

fn getDeg(s: *Sort, e: anytype) c.gint {
    const v: isize = @bitCast(@intFromPtr(c.g_hash_table_lookup(s.hash, @ptrCast(@constCast(e)))));
    return @as(c.gint, @intCast(v)) - 1;
}

fn enqueue(s: *Sort, e: [*c]Element) void {
    _ = c.gst_object_ref(e);
    c.g_queue_push_tail(&s.queue, e);
    setDeg(s, e, -1);
}

fn dequeue(s: *Sort, e: [*c]Element) void {
    const found = c.g_queue_find(&s.queue, e);
    if (found == null) return;
    c.g_queue_delete_link(&s.queue, found);
    c.gst_object_unref(e);
}

fn clearQueue(q: *c.GQueue) void {
    while (c.g_queue_pop_head(q)) |p| c.gst_object_unref(p);
}

fn copyOne(data: c.gpointer, q: c.gpointer) callconv(.c) void {
    _ = c.gst_object_ref(data);
    c.g_queue_push_tail(@ptrCast(@alignCast(q)), data);
}

fn sortCopy(src_it: [*c]const c.GstIterator, dst_it: [*c]c.GstIterator) callconv(.c) void {
    const src: *const Sort = @ptrCast(@alignCast(src_it));
    const dst: *Sort = @ptrCast(@alignCast(dst_it));
    c.g_queue_init(&dst.queue);
    c.g_queue_foreach(@constCast(&src.queue), copyOne, &dst.queue);
    dst.bin = @ptrCast(@alignCast(c.gst_object_ref(src.bin)));
    if (src.best != null) dst.best = @ptrCast(@alignCast(c.gst_object_ref(src.best)));
    dst.hash = c.g_hash_table_new(null, null);
    var iter: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&iter, src.hash);
    var k: c.gpointer = null;
    var v: c.gpointer = null;
    while (c.g_hash_table_iter_next(&iter, &k, &v) != 0) _ = c.g_hash_table_insert(dst.hash, k, v);
}

fn resetDegree(data: c.gpointer, sd: c.gpointer) callconv(.c) void {
    const s: *Sort = @ptrCast(@alignCast(sd));
    const e: [*c]Element = @ptrCast(@alignCast(data));
    if (isSinkChild(e)) enqueue(s, e) else setDeg(s, e, 0);
}

fn updateDegree(data: c.gpointer, sd: c.gpointer) callconv(.c) void {
    const s: *Sort = @ptrCast(@alignCast(sd));
    const e: [*c]Element = @ptrCast(@alignCast(data));
    lock(e);
    defer unlock(e);
    if (e[0].numsinkpads == 0) return;
    var l = e[0].sinkpads;
    while (l != null) : (l = l[0].next) {
        const p: [*c]pad.Pad = @ptrCast(@alignCast(l[0].data));
        if (findMessage(s.bin, @ptrCast(p), c.GST_MESSAGE_STRUCTURE_CHANGE) != null) {
            s.dirty = 1;
            continue;
        }
        const peer = pad.gst_pad_get_peer(p);
        if (peer == null) continue;
        const pe = pad.gst_pad_get_parent_element(peer);
        if (pe != null) {
            lock(pe);
            if (parentOf(pe) == @as([*c]Obj, @ptrCast(s.bin))) {
                var old = getDeg(s, pe);
                if (old == -1) {
                    dequeue(s, pe);
                    old = 0;
                }
                const new = old + s.mode;
                if (new == 0) enqueue(s, pe) else setDeg(s, pe, new);
            }
            unlock(pe);
            c.gst_object_unref(pe);
        }
        c.gst_object_unref(peer);
    }
}

fn findBest(data: c.gpointer, sd: c.gpointer) callconv(.c) void {
    const s: *Sort = @ptrCast(@alignCast(sd));
    const e: [*c]Element = @ptrCast(@alignCast(data));
    const d = getDeg(s, e);
    if (d < 0) return;
    if (s.best == null or s.best_deg > d) {
        s.best = e;
        s.best_deg = d;
    } else if (s.best_deg == d and has(s.best, c.GST_ELEMENT_FLAG_SOURCE) and !has(e, c.GST_ELEMENT_FLAG_SOURCE)) s.best = e;
}

fn sortNext(it: [*c]c.GstIterator, result: [*c]c.GValue) callconv(.c) c.GstIteratorResult {
    const s: *Sort = @ptrCast(@alignCast(it));
    var best: [*c]Element = null;
    if (c.g_queue_is_empty(&s.queue) != 0) {
        s.best = null;
        s.best_deg = std.math.maxInt(c.gint);
        c.g_list_foreach(s.bin[0].children, findBest, s);
        best = s.best;
        if (best == null) return c.GST_ITERATOR_DONE;
        if (s.best_deg != 0 and s.dirty == 0) c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "loop detected in the graph of bin '%s'!!", pad.nameOf(@ptrCast(s.bin)));
        setDeg(s, best, -1);
        c.g_value_set_object(result, best);
    } else {
        best = @ptrCast(@alignCast(c.g_queue_pop_head(&s.queue)));
        c.g_value_set_object(result, best);
        c.gst_object_unref(best);
    }
    updateDegree(best, s);
    return c.GST_ITERATOR_OK;
}

fn sortResync(it: [*c]c.GstIterator) callconv(.c) void {
    const s: *Sort = @ptrCast(@alignCast(it));
    s.dirty = 0;
    clearQueue(&s.queue);
    c.g_list_foreach(s.bin[0].children, resetDegree, s);
    s.mode = 1;
    c.g_list_foreach(s.bin[0].children, updateDegree, s);
    s.mode = -1;
}

fn sortFree(it: [*c]c.GstIterator) callconv(.c) void {
    const s: *Sort = @ptrCast(@alignCast(it));
    clearQueue(&s.queue);
    c.g_hash_table_destroy(s.hash);
    c.gst_object_unref(s.bin);
}

fn sortIterator(b: [*c]Bin) [*c]c.GstIterator {
    const it = c.gst_iterator_new(@sizeOf(Sort), element.gst_element_get_type(), @ptrCast(&@as([*c]Obj, @ptrCast(b))[0].lock), &priv(b).structure_cookie, sortCopy, sortNext, null, sortResync, sortFree);
    const s: *Sort = @ptrCast(@alignCast(it));
    c.g_queue_init(&s.queue);
    s.hash = c.g_hash_table_new(null, null);
    s.bin = @ptrCast(@alignCast(c.gst_object_ref(b)));
    sortResync(it);
    return it;
}

pub export fn gst_bin_iterate_sorted(b: [*c]Bin) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_sorted", "GST_IS_BIN (bin)")) return null;
    lock(b);
    defer unlock(b);
    return sortIterator(b);
}

fn childSetState(b: [*c]Bin, e: [*c]Element, base: c.GstClockTime, start: c.GstClockTime, cur: c.GstState, next: c.GstState) c.GstStateChangeReturn {
    stateLock(e);
    defer stateUnlock(e);
    lock(e);
    e[0].start_time = start;
    e[0].base_time = @bitCast(base);
    const locked = has(e, c.GST_ELEMENT_FLAG_LOCKED_STATE);
    var ret = e[0].last_return;
    const cc = e[0].current_state;
    const cp = e[0].pending_state;
    unlock(e);
    if (locked) return if (ret == c.GST_STATE_CHANGE_FAILURE) c.GST_STATE_CHANGE_SUCCESS else ret;
    if (ret != c.GST_STATE_CHANGE_NO_PREROLL) {
        if (!isBin(e)) {
            if (cc == next and cp == c.GST_STATE_VOID_PENDING) return ret;
            if (next > cur) {
                const skip = if (cp == c.GST_STATE_VOID_PENDING) cc > next else if (cp > cc) cc >= next else cc > next;
                if (skip) return c.GST_STATE_CHANGE_SUCCESS;
            } else if (next < cur) {
                const skip = if (cp == c.GST_STATE_VOID_PENDING) cc < next else if (cp < cc) cc <= next else cc < next;
                if (skip) return c.GST_STATE_CHANGE_SUCCESS;
            }
        }
        lock(b);
        if (findMessage(b, @ptrCast(e), c.GST_MESSAGE_ASYNC_START) != null and next > cur) {
            unlock(b);
            return c.GST_STATE_CHANGE_ASYNC;
        }
        unlock(b);
    }
    ret = element.gst_element_set_state(e, next);
    return ret;
}

fn activateFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const p: [*c]pad.Pad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    const active: *c.gboolean = @ptrCast(@alignCast(data));
    if (pad.gst_pad_set_active(p, active.*) == 0 and pad.parentOf(p) != null) {
        c.g_value_set_boolean(ret, 0);
        return 0;
    }
    return 1;
}

fn srcPadsActivate(b: [*c]Bin, on: bool) bool {
    var active: c.gboolean = @intFromBool(on);
    const it = element.gst_element_iterate_src_pads(el(b));
    defer c.gst_iterator_free(it);
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&ret, 1);
    while (true) {
        switch (c.gst_iterator_fold(it, activateFold, &ret, &active)) {
            c.GST_ITERATOR_RESYNC => {
                c.g_value_set_boolean(&ret, 1);
                c.gst_iterator_resync(it);
            },
            c.GST_ITERATOR_DONE => break,
            else => {
                c.g_value_set_boolean(&ret, 0);
                break;
            },
        }
    }
    return c.g_value_get_boolean(&ret) != 0;
}

pub export fn gst_bin_recalculate_latency(b: [*c]Bin) c.gboolean {
    var res: c.gboolean = 0;
    c.g_signal_emit(b, sig_latency, 0, &res);
    return res;
}

fn timeParts(t: u64) struct { c.guint, c.guint, c.guint, c.guint } {
    if (t == NONE) return .{ 99, 99, 99, 999999999 };
    const s: u64 = 1000000000;
    return .{ @intCast(t / (s * 3600)), @intCast((t / (s * 60)) % 60), @intCast((t / s) % 60), @intCast(t % s) };
}

fn doLatency(b: [*c]Bin) callconv(.c) c.gboolean {
    if (!check.that(isBin(b), "gst_bin_do_latency_func", "GST_IS_BIN (bin)")) return 0;
    const e = el(b);
    const q = c.gst_query_new_latency();
    defer c.gst_query_unref(q);
    var res = element.gst_element_query(e, q);
    if (res != 0) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        c.gst_query_parse_latency(q, &live, &min, &max);
        if (max < min) {
            const a = timeParts(max);
            const z = timeParts(min);
            const dbg = c.g_strdup_printf("Impossible to configure latency: max %u:%02u:%02u.%09u < min %u:%02u:%02u.%09u. Add queues or other buffering elements.", a[0], a[1], a[2], a[3], z[0], z[1], z[2], z[3]);
            element.gst_element_message_full(e, c.GST_MESSAGE_WARNING, c.gst_core_error_quark(), c.GST_CORE_ERROR_CLOCK, null, dbg, "../gst/gstbin.c", "gst_bin_do_latency_func", 2756);
        }
        res = element.gst_element_send_event(e, c.gst_event_new_latency(min));
    }
    return res;
}

fn postMessage(e: [*c]Element, m: [*c]Msg) callconv(.c) c.gboolean {
    const ret = parent_class.?.post_message.?(e, @ptrCast(c.gst_mini_object_ref(@ptrCast(m))));
    if (m[0].type == c.GST_MESSAGE_STATE_CHANGED and m[0].src == @as([*c]Obj, @ptrCast(e))) {
        var new: c.GstState = 0;
        var pending: c.GstState = 0;
        c.gst_message_parse_state_changed(m, null, &new, &pending);
        const b: [*c]Bin = @ptrCast(@alignCast(e));
        if (new == c.GST_STATE_PLAYING and pending == c.GST_STATE_VOID_PENDING) {
            priv(b).posted_playing = 1;
            doEos(b);
        } else priv(b).posted_playing = 0;
    }
    c.gst_mini_object_unref(@ptrCast(m));
    return ret;
}

fn resetState(item: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    _ = element.gst_element_set_state(@ptrCast(@alignCast(c.g_value_get_object(item))), @intCast(@intFromPtr(data)));
}

fn changeState(e: [*c]Element, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const b: [*c]Bin = @ptrCast(@alignCast(e));
    const cur: c.GstState = @intCast(t >> 3);
    const next: c.GstState = @intCast(t & 0x7);
    switch (next) {
        c.GST_STATE_PLAYING => {
            lock(b);
            const top = toplevel(b);
            const ah = priv(b).asynchandling != 0;
            unlock(b);
            if (top) _ = gst_bin_recalculate_latency(b);
            if (ah) _ = element.gst_element_post_message(e, c.gst_message_new_latency(@ptrCast(e)));
        },
        c.GST_STATE_PAUSED => {
            lock(b);
            removeMessages(b, null, c.GST_MESSAGE_EOS);
            priv(b).posted_eos = 0;
            if (cur == c.GST_STATE_READY) removeMessages(b, null, c.GST_MESSAGE_STREAM_START);
            unlock(b);
            if (cur == c.GST_STATE_READY and !srcPadsActivate(b, true)) return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_READY => {
            lock(b);
            removeMessages(b, null, c.GST_MESSAGE_ANY);
            unlock(b);
            if (cur != c.GST_STATE_NULL and !srcPadsActivate(b, false)) return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_NULL => {
            lock(b);
            removeMessages(b, null, c.GST_MESSAGE_ANY);
            unlock(b);
            if (cur == c.GST_STATE_READY and !srcPadsActivate(b, false)) return c.GST_STATE_CHANGE_FAILURE;
        },
        else => {},
    }
    lock(b);
    b[0].polling = 1;
    unlock(b);
    const it = gst_bin_iterate_sorted(b);
    var have_async = false;
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    var item = std.mem.zeroes(c.GValue);
    var failed = false;
    outer: while (true) {
        const base: u64 = element.gst_element_get_base_time(e);
        const start = element.gst_element_get_start_time(e);
        var no_preroll = false;
        while (true) {
            switch (c.gst_iterator_next(it, &item)) {
                c.GST_ITERATOR_OK => {
                    const child: [*c]Element = @ptrCast(@alignCast(c.g_value_get_object(&item)));
                    ret = childSetState(b, child, base, start, cur, next);
                    switch (ret) {
                        c.GST_STATE_CHANGE_ASYNC => have_async = true,
                        c.GST_STATE_CHANGE_FAILURE => {
                            const parent = c.gst_object_get_parent(@ptrCast(child));
                            if (parent != null) c.gst_object_unref(parent);
                            if (parent == @as([*c]Obj, @ptrCast(e))) {
                                failed = true;
                                break :outer;
                            }
                        },
                        c.GST_STATE_CHANGE_NO_PREROLL => no_preroll = true,
                        else => {},
                    }
                    _ = c.g_value_reset(&item);
                },
                c.GST_ITERATOR_RESYNC => {
                    c.gst_iterator_resync(it);
                    continue :outer;
                },
                else => break,
            }
        }
        ret = parent_class.?.change_state.?(e, t);
        if (ret != c.GST_STATE_CHANGE_FAILURE) {
            if (no_preroll) {
                ret = c.GST_STATE_CHANGE_NO_PREROLL;
            } else if (have_async) ret = c.GST_STATE_CHANGE_ASYNC;
        }
        break;
    }
    if (failed and cur < next) {
        const undo = gst_bin_iterate_sorted(b);
        while (c.gst_iterator_foreach(undo, resetState, @ptrFromInt(@as(usize, @intCast(cur)))) == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(undo);
        c.gst_iterator_free(undo);
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    lock(b);
    b[0].polling = 0;
    if ((ret == c.GST_STATE_CHANGE_ASYNC or priv(b).pending_async_done != 0) and e[0].target_state > c.GST_STATE_READY) {
        if (findMessage(b, null, c.GST_MESSAGE_ASYNC_START) == null) {
            removeMessages(b, null, c.GST_MESSAGE_ASYNC_DONE);
            asyncDone(b, c.GST_STATE_CHANGE_SUCCESS, false, NONE);
        }
    }
    priv(b).pending_async_done = 0;
    unlock(b);
    return ret;
}

const EventSend = struct { event: [*c]c.GstEvent, res: c.gboolean };

fn sendToChild(s: *EventSend, child: c.gpointer) void {
    s.res &= element.gst_element_send_event(@ptrCast(@alignCast(child)), @ptrCast(c.gst_mini_object_ref(@ptrCast(s.event))));
}

fn sendToPad(s: *EventSend, p: c.gpointer) void {
    s.res &= padflow.gst_pad_send_event(@ptrCast(@alignCast(p)), @ptrCast(c.gst_mini_object_ref(@ptrCast(s.event))));
}

fn resetSend(s: *EventSend) void {
    s.res = 1;
}

fn sendEvent(e: [*c]Element, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const b: [*c]Bin = @ptrCast(@alignCast(e));
    var s = EventSend{ .event = ev, .res = 1 };
    const down = ev[0].type & c.GST_EVENT_TYPE_DOWNSTREAM != 0;
    eachChild(if (down) gst_bin_iterate_sources(b) else gst_bin_iterate_sinks(b), &s, sendToChild, resetSend);
    eachChildNoReset(if (down) element.gst_element_iterate_sink_pads(e) else element.gst_element_iterate_src_pads(e), &s);
    c.gst_mini_object_unref(@ptrCast(ev));
    return s.res;
}

fn eachChildNoReset(it: [*c]c.GstIterator, s: *EventSend) void {
    var item = std.mem.zeroes(c.GValue);
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => sendToPad(s, c.g_value_get_object(&item)),
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                s.res = 1;
            },
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
}

fn continueFunc(o: [*c]Obj, data: c.gpointer) callconv(.c) void {
    const b: [*c]Bin = @ptrCast(@alignCast(o));
    const d: *Continue = @ptrCast(@alignCast(data));
    defer std.heap.c_allocator.destroy(d);
    const e = el(b);
    stateLock(e);
    defer stateUnlock(e);
    lock(b);
    if (d.cookie != e[0].state_cookie) {
        unlock(b);
        return;
    }
    const cur = e[0].current_state;
    const next = nextState(cur, d.pending);
    e[0].next_state = next;
    e[0].pending_state = d.pending;
    e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
    unlock(b);
    _ = element.gst_element_change_state(e, @intCast((cur << 3) | next));
}

fn asyncStart(b: [*c]Bin) void {
    const e = el(b);
    if (e[0].last_return == c.GST_STATE_CHANGE_FAILURE) return;
    const am: [*c]Msg = if (!toplevel(b)) c.gst_message_new_async_start(@ptrCast(b)) else null;
    if (b[0].polling != 0 or e[0].pending_state != c.GST_STATE_VOID_PENDING or e[0].last_return == c.GST_STATE_CHANGE_NO_PREROLL) {
        unlock(b);
    } else {
        const old = e[0].current_state;
        const new: c.GstState = if (old > c.GST_STATE_PAUSED) c.GST_STATE_PAUSED else old;
        e[0].current_state = new;
        e[0].next_state = new;
        e[0].pending_state = new;
        e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
        unlock(b);
        element._priv_gst_element_state_changed(e, new, new, new);
    }
    if (am != null) _ = element.gst_element_post_message(e, am);
    lock(b);
}

fn asyncDone(b: [*c]Bin, ret: c.GstStateChangeReturn, flag_pending: bool, running: c.GstClockTime) void {
    const e = el(b);
    if (e[0].last_return == c.GST_STATE_CHANGE_FAILURE) return;
    var pending = e[0].pending_state;
    if (b[0].polling != 0) {
        if (flag_pending) priv(b).pending_async_done = 1;
        return;
    }
    if (pending == c.GST_STATE_VOID_PENDING) {
        const am = c.gst_message_new_async_done(@ptrCast(b), running);
        unlock(b);
        _ = element.gst_element_post_message(e, am);
        lock(b);
        return;
    }
    const old_ret = e[0].last_return;
    e[0].last_return = ret;
    pending = e[0].target_state;
    e[0].pending_state = pending;
    const am = c.gst_message_new_async_done(@ptrCast(b), running);
    const old_state = e[0].current_state;
    const old_next = e[0].next_state;
    var cur = old_state;
    if (old_next != c.GST_STATE_PLAYING) {
        e[0].current_state = old_next;
        cur = old_next;
    }
    var cont: ?*Continue = null;
    if (pending == cur or !toplevel(b)) {
        pending = c.GST_STATE_VOID_PENDING;
        e[0].pending_state = pending;
        e[0].next_state = c.GST_STATE_VOID_PENDING;
    } else {
        cont = std.heap.c_allocator.create(Continue) catch null;
        if (cont) |k| k.* = .{ .cookie = e[0].state_cookie, .pending = pending };
        e[0].last_return = c.GST_STATE_CHANGE_ASYNC;
        e[0].next_state = nextState(old_state, pending);
    }
    const changed = old_next != c.GST_STATE_PLAYING and (old_state != old_next or old_ret == c.GST_STATE_CHANGE_ASYNC);
    unlock(b);
    if (changed) element._priv_gst_element_state_changed(e, old_state, old_next, pending);
    _ = element.gst_element_post_message(e, am);
    lock(b);
    if (cont) |k| {
        element.callAsync(@ptrCast(b), @ptrCast(&continueFunc), k, null);
    } else c.g_cond_broadcast(@ptrCast(&e[0].state_cond));
}

fn doEos(b: [*c]Bin) void {
    var seqnum: c.guint32 = c.GST_SEQNUM_INVALID;
    const e = el(b);
    lock(b);
    const eos = e[0].current_state == c.GST_STATE_PLAYING and (e[0].pending_state == c.GST_STATE_VOID_PENDING or e[0].pending_state == c.GST_STATE_PLAYING) and priv(b).posted_playing != 0 and isEos(b, &seqnum);
    unlock(b);
    if (!eos or @cmpxchgStrong(c.gint, &priv(b).posted_eos, 0, 1, .seq_cst, .seq_cst) != null) return;
    lock(b);
    removeMessages(b, null, c.GST_MESSAGE_EOS);
    priv(b).posted_eos = 0;
    unlock(b);
    const m = c.gst_message_new_eos(@ptrCast(b));
    if (seqnum != c.GST_SEQNUM_INVALID) c.gst_message_set_seqnum(m, seqnum);
    _ = element.gst_element_post_message(e, m);
}

fn doStreamStart(b: [*c]Bin) void {
    var seqnum: c.guint32 = c.GST_SEQNUM_INVALID;
    var have_group = false;
    var group: c.guint = 0;
    lock(b);
    const ok = isStreamStart(b, &seqnum, &have_group, &group);
    unlock(b);
    if (!ok) return;
    lock(b);
    removeMessages(b, null, c.GST_MESSAGE_STREAM_START);
    unlock(b);
    const m = c.gst_message_new_stream_start(@ptrCast(b));
    if (seqnum != c.GST_SEQNUM_INVALID) c.gst_message_set_seqnum(m, seqnum);
    if (have_group) c.gst_message_set_group_id(m, group);
    _ = element.gst_element_post_message(el(b), m);
}

fn forwardCopy(b: [*c]Bin, m: [*c]Msg) void {
    if (priv(b).message_forward == 0) return;
    const s = c.gst_structure_new_empty("GstBinForwarded");
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_message_get_type());
    c.g_value_set_boxed(&v, m);
    c.gst_structure_take_value(s, "message", &v);
    _ = element.gst_element_post_message(el(b), c.gst_message_new_element(@ptrCast(b), s));
}

fn updateContextUnlocked(b: [*c]Bin, ctx: ?*c.GstContext) void {
    const list: *[*c]c.GList = @ptrCast(&el(b)[0].contexts);
    const kind = c.gst_context_get_context_type(ctx);
    var l = list.*;
    while (l != null) : (l = l[0].next) {
        const tmp: ?*c.GstContext = @ptrCast(l[0].data);
        if (c.strcmp(kind, c.gst_context_get_context_type(tmp)) == 0 and (c.gst_context_is_persistent(ctx) != 0 or c.gst_context_is_persistent(tmp) == 0)) {
            _ = c.gst_context_replace(@ptrCast(&l[0].data), ctx);
            return;
        }
    }
    list.* = c.g_list_prepend(list.*, c.gst_context_ref(ctx));
}

fn copyMini(src: c.gconstpointer, _: c.gpointer) callconv(.c) c.gpointer {
    return c.gst_mini_object_ref(@ptrCast(@alignCast(@constCast(src))));
}

fn unrefMini(p: c.gpointer) callconv(.c) void {
    c.gst_mini_object_unref(@ptrCast(@alignCast(p)));
}

fn handleMessage(b: [*c]Bin, m_in: [*c]Msg) callconv(.c) void {
    var m = m_in;
    const src = m[0].src;
    const e = el(b);
    switch (m[0].type) {
        c.GST_MESSAGE_ERROR => {
            lock(b);
            e[0].last_return = c.GST_STATE_CHANGE_FAILURE;
            c.g_cond_broadcast(@ptrCast(&e[0].state_cond));
            unlock(b);
        },
        c.GST_MESSAGE_EOS => {
            forwardCopy(b, m);
            lock(b);
            replaceMessage(b, m, c.GST_MESSAGE_EOS);
            unlock(b);
            doEos(b);
            return;
        },
        c.GST_MESSAGE_STREAM_START => {
            lock(b);
            replaceMessage(b, m, c.GST_MESSAGE_STREAM_START);
            unlock(b);
            doStreamStart(b);
            return;
        },
        c.GST_MESSAGE_STATE_DIRTY => {
            c.gst_mini_object_unref(@ptrCast(m));
            return;
        },
        c.GST_MESSAGE_SEGMENT_START, c.GST_MESSAGE_SEGMENT_DONE => {
            var format: c.GstFormat = 0;
            var pos: c.gint64 = 0;
            const start = m[0].type == c.GST_MESSAGE_SEGMENT_START;
            if (start) c.gst_message_parse_segment_start(m, &format, &pos) else c.gst_message_parse_segment_done(m, &format, &pos);
            const seqnum = c.gst_message_get_seqnum(m);
            forwardCopy(b, m);
            lock(b);
            var post = false;
            if (start) {
                post = findMessage(b, null, c.GST_MESSAGE_SEGMENT_START) == null and parentOf(b) != null;
                replaceMessage(b, m, c.GST_MESSAGE_SEGMENT_START);
            } else {
                replaceMessage(b, m, c.GST_MESSAGE_SEGMENT_START);
                if (findMessage(b, null, c.GST_MESSAGE_SEGMENT_START) == null) {
                    post = true;
                    removeMessages(b, null, c.GST_MESSAGE_SEGMENT_DONE);
                }
            }
            unlock(b);
            if (post) {
                const t = if (start) c.gst_message_new_segment_start(@ptrCast(b), format, pos) else c.gst_message_new_segment_done(@ptrCast(b), format, pos);
                c.gst_message_set_seqnum(t, seqnum);
                _ = element.gst_element_post_message(e, t);
            }
            return;
        },
        c.GST_MESSAGE_CLOCK_LOST => {
            var clock: [*c]c.GstClock = null;
            c.gst_message_parse_clock_lost(m, &clock);
            lock(b);
            b[0].clock_dirty = 1;
            const provided = clock == b[0].provided_clock;
            const playing = e[0].current_state == c.GST_STATE_PLAYING;
            const forward = provided and (playing or parentOf(b) != null);
            if (provided) {
                _ = object.gst_object_replace(@ptrCast(&b[0].provided_clock), null);
                _ = object.gst_object_replace(@ptrCast(&b[0].clock_provider), null);
            }
            unlock(b);
            if (!forward) {
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
        },
        c.GST_MESSAGE_CLOCK_PROVIDE => {
            lock(b);
            b[0].clock_dirty = 1;
            const forward = parentOf(b) != null;
            unlock(b);
            if (!forward) {
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
        },
        c.GST_MESSAGE_ASYNC_START => {
            forwardCopy(b, m);
            lock(b);
            if (e[0].target_state <= c.GST_STATE_READY) {
                unlock(b);
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
            replaceMessage(b, m, c.GST_MESSAGE_ASYNC_START);
            asyncStart(b);
            unlock(b);
            return;
        },
        c.GST_MESSAGE_ASYNC_DONE => {
            var running: c.GstClockTime = 0;
            c.gst_message_parse_async_done(m, &running);
            forwardCopy(b, m);
            lock(b);
            if (e[0].target_state <= c.GST_STATE_READY) {
                unlock(b);
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
            replaceMessage(b, m, c.GST_MESSAGE_ASYNC_START);
            if (findMessage(b, null, c.GST_MESSAGE_ASYNC_START) == null) {
                removeMessages(b, null, c.GST_MESSAGE_ASYNC_DONE);
                asyncDone(b, c.GST_STATE_CHANGE_SUCCESS, true, running);
            }
            unlock(b);
            return;
        },
        c.GST_MESSAGE_STRUCTURE_CHANGE => {
            var busy: c.gboolean = 0;
            c.gst_message_parse_structure_change(m, null, null, &busy);
            lock(b);
            if (busy != 0) {
                replaceMessage(b, m, c.GST_MESSAGE_STRUCTURE_CHANGE);
                m = null;
            } else {
                removeMessages(b, m[0].src, c.GST_MESSAGE_STRUCTURE_CHANGE);
                if (!noResync(b)) priv(b).structure_cookie +%= 1;
            }
            unlock(b);
            if (m != null) c.gst_mini_object_unref(@ptrCast(m));
            return;
        },
        c.GST_MESSAGE_NEED_CONTEXT => {
            var kind: [*c]const u8 = null;
            _ = c.gst_message_parse_context_type(m, &kind);
            if (src == null) {
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "Got need-context message in bin '%s' without source element, dropping", pad.nameOf(@ptrCast(b)));
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
            lock(b);
            const list = c.g_list_copy_deep(e[0].contexts, copyMini, null);
            unlock(b);
            var l = list;
            while (l != null) : (l = l[0].next) {
                if (c.strcmp(kind, c.gst_context_get_context_type(@ptrCast(l[0].data))) == 0) {
                    element.gst_element_set_context(@ptrCast(@alignCast(src)), @ptrCast(l[0].data));
                    break;
                }
            }
            c.g_list_free_full(list, unrefMini);
            if (l != null) {
                c.gst_mini_object_unref(@ptrCast(m));
                return;
            }
        },
        c.GST_MESSAGE_HAVE_CONTEXT => {
            var ctx: ?*c.GstContext = null;
            c.gst_message_parse_have_context(m, &ctx);
            lock(b);
            updateContextUnlocked(b, ctx);
            unlock(b);
            c.gst_context_unref(ctx);
        },
        else => {},
    }
    _ = element.gst_element_post_message(e, m);
}

const Fold = extern struct {
    query: [*c]c.GstQuery,
    min: c.gint64,
    max: c.gint64,
    live: c.gboolean,
};

fn foldInit(f: *Fold) void {
    f.min = 0;
    f.max = -1;
    f.live = 0;
}

fn runQuery(item: [*c]const c.GValue, q: [*c]c.GstQuery) bool {
    const o = c.g_value_get_object(item);
    if (pad.isPad(o)) return padflow.gst_pad_query(@ptrCast(@alignCast(o)), q) != 0;
    return element.gst_element_query(@ptrCast(@alignCast(o)), q) != 0;
}

fn durationFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (!runQuery(item, f.query)) return 1;
    c.g_value_set_boolean(ret, 1);
    var d: c.gint64 = 0;
    c.gst_query_parse_duration(f.query, null, &d);
    if (d == -1) {
        f.max = -1;
        return 0;
    }
    if (d > f.max) f.max = d;
    return 1;
}

fn positionFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (!runQuery(item, f.query)) return 1;
    c.g_value_set_boolean(ret, 1);
    var p: c.gint64 = 0;
    c.gst_query_parse_position(f.query, null, &p);
    if (p > f.max) f.max = p;
    return 1;
}

fn latencyFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (!runQuery(item, f.query)) {
        c.g_value_set_boolean(ret, 0);
        return 1;
    }
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    c.gst_query_parse_latency(f.query, &live, &min, &max);
    if (live != 0) {
        const mi: i64 = @bitCast(min);
        const ma: i64 = @bitCast(max);
        if (mi > f.min) f.min = mi;
        if (f.max == -1) f.max = ma else if (ma < f.max) f.max = ma;
        if (f.live == 0) f.live = live;
    }
    return 1;
}

fn genericFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    const ok = runQuery(item, f.query);
    if (ok) c.g_value_set_boolean(ret, 1);
    return @intFromBool(!ok);
}

const Kind = enum { duration, position, latency, generic };

fn foldDone(kind: Kind, f: *Fold) void {
    switch (kind) {
        .duration => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_duration(f.query, &format, null);
            c.gst_query_set_duration(f.query, format, f.max);
        },
        .position => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(f.query, &format, null);
            c.gst_query_set_position(f.query, format, f.max);
        },
        .latency => c.gst_query_set_latency(f.query, f.live, @bitCast(f.min), @bitCast(f.max)),
        .generic => {},
    }
}

fn iterateFold(it: [*c]c.GstIterator, kind: Kind, func: c.GstIteratorFoldFunction, f: *Fold, default: bool) bool {
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&ret, @intFromBool(default));
    while (true) {
        switch (c.gst_iterator_fold(it, func, &ret, f)) {
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                if (kind != .generic) foldInit(f);
                c.g_value_set_boolean(&ret, @intFromBool(default));
            },
            c.GST_ITERATOR_OK, c.GST_ITERATOR_DONE => {
                const res = c.g_value_get_boolean(&ret) != 0;
                if (kind != .generic and res) foldDone(kind, f);
                return res;
            },
            else => return false,
        }
    }
}

fn query(e: [*c]Element, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const b: [*c]Bin = @ptrCast(@alignCast(e));
    var kind: Kind = .generic;
    var func: c.GstIteratorFoldFunction = genericFold;
    var default = false;
    switch (q[0].type) {
        c.GST_QUERY_DURATION => {
            kind = .duration;
            func = durationFold;
        },
        c.GST_QUERY_POSITION => {
            kind = .position;
            func = positionFold;
        },
        c.GST_QUERY_LATENCY => {
            kind = .latency;
            func = latencyFold;
            default = true;
        },
        else => {},
    }
    var f = Fold{ .query = q, .min = 0, .max = 0, .live = 0 };
    if (kind != .generic) foldInit(&f);
    var it = gst_bin_iterate_sinks(b);
    var res = iterateFold(it, kind, func, &f, default);
    c.gst_iterator_free(it);
    if (!res) {
        it = element.gst_element_iterate_src_pads(e);
        res = iterateFold(it, kind, func, &f, default);
        c.gst_iterator_free(it);
    }
    return @intFromBool(res);
}

fn setChildContext(item: [*c]const c.GValue, data: c.gpointer) callconv(.c) void {
    element.gst_element_set_context(@ptrCast(@alignCast(c.g_value_get_object(item))), @ptrCast(data));
}

fn setContext(e: [*c]Element, ctx: ?*c.GstContext) callconv(.c) void {
    if (!check.that(isBin(e), "gst_bin_set_context", "GST_IS_BIN (element)")) return;
    parent_class.?.set_context.?(e, ctx);
    const it = gst_bin_iterate_elements(@ptrCast(@alignCast(e)));
    while (c.gst_iterator_foreach(it, setChildContext, ctx) == c.GST_ITERATOR_RESYNC) c.gst_iterator_resync(it);
    c.gst_iterator_free(it);
}

fn compareName(a: c.gconstpointer, n: c.gconstpointer) callconv(.c) c.gint {
    const e = c.g_value_get_object(@ptrCast(@alignCast(a)));
    lock(e);
    defer unlock(e);
    return c.strcmp(object.of(e).name, @ptrCast(n));
}

pub export fn gst_bin_get_by_name(b: [*c]Bin, name: [*c]const u8) [*c]Element {
    if (!check.that(isBin(b), "gst_bin_get_by_name", "GST_IS_BIN (bin)")) return null;
    const it = gst_bin_iterate_recurse(b);
    var result = std.mem.zeroes(c.GValue);
    const found = c.gst_iterator_find_custom(it, compareName, &result, @constCast(name)) != 0;
    c.gst_iterator_free(it);
    if (!found) return null;
    const r: [*c]Element = @ptrCast(@alignCast(c.g_value_dup_object(&result)));
    c.g_value_unset(&result);
    return r;
}

pub export fn gst_bin_get_by_name_recurse_up(b: [*c]Bin, name: [*c]const u8) [*c]Element {
    if (!check.that(isBin(b), "gst_bin_get_by_name_recurse_up", "GST_IS_BIN (bin)")) return null;
    if (!check.that(name != null, "gst_bin_get_by_name_recurse_up", "name != NULL")) return null;
    var r = gst_bin_get_by_name(b, name);
    if (r != null) return r;
    const parent = c.gst_object_get_parent(@ptrCast(b));
    if (parent == null) return null;
    if (isBin(parent)) r = gst_bin_get_by_name_recurse_up(@ptrCast(@alignCast(parent)), name);
    c.gst_object_unref(parent);
    return r;
}

fn compareIface(a: c.gconstpointer, iface: c.gconstpointer) callconv(.c) c.gint {
    const e = c.g_value_get_object(@ptrCast(@alignCast(a)));
    const t: c.GType = @intFromPtr(c.g_value_get_pointer(@ptrCast(@alignCast(iface))));
    return @intFromBool(!gtype.instanceOf(e, t));
}

fn ifaceValue(iface: c.GType) c.GValue {
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, 17 << c.G_TYPE_FUNDAMENTAL_SHIFT);
    c.g_value_set_pointer(&v, @ptrFromInt(iface));
    return v;
}

fn isInterface(t: c.GType) bool {
    return c.g_type_fundamental(t) == 2 << c.G_TYPE_FUNDAMENTAL_SHIFT;
}

pub export fn gst_bin_get_by_interface(b: [*c]Bin, iface: c.GType) [*c]Element {
    if (!check.that(isBin(b), "gst_bin_get_by_interface", "GST_IS_BIN (bin)")) return null;
    if (!check.that(isInterface(iface), "gst_bin_get_by_interface", "G_TYPE_IS_INTERFACE (iface)")) return null;
    var v = ifaceValue(iface);
    defer c.g_value_unset(&v);
    const it = gst_bin_iterate_recurse(b);
    var result = std.mem.zeroes(c.GValue);
    const found = c.gst_iterator_find_custom(it, compareIface, &result, &v) != 0;
    c.gst_iterator_free(it);
    if (!found) return null;
    const r: [*c]Element = @ptrCast(@alignCast(c.g_value_dup_object(&result)));
    c.g_value_unset(&result);
    return r;
}

pub export fn gst_bin_iterate_all_by_interface(b: [*c]Bin, iface: c.GType) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_all_by_interface", "GST_IS_BIN (bin)")) return null;
    if (!check.that(isInterface(iface), "gst_bin_iterate_all_by_interface", "G_TYPE_IS_INTERFACE (iface)")) return null;
    var v = ifaceValue(iface);
    defer c.g_value_unset(&v);
    return c.gst_iterator_filter(gst_bin_iterate_recurse(b), compareIface, &v);
}

fn compareFactory(a: c.gconstpointer, n: c.gconstpointer) callconv(.c) c.gint {
    const e: [*c]Element = @ptrCast(@alignCast(c.g_value_get_object(@ptrCast(@alignCast(a)))));
    const f = element.gst_element_get_factory(e);
    if (f == null) return -1;
    return c.g_strcmp0(object.of(f).name, c.g_value_get_string(@ptrCast(@alignCast(n))));
}

pub export fn gst_bin_iterate_all_by_element_factory_name(b: [*c]Bin, name: [*c]const u8) [*c]c.GstIterator {
    if (!check.that(isBin(b), "gst_bin_iterate_all_by_element_factory_name", "GST_IS_BIN (bin)")) return null;
    if (!check.that(name != null and name[0] != 0, "gst_bin_iterate_all_by_element_factory_name", "factory_name && *factory_name")) return null;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_STRING);
    c.g_value_set_string(&v, name);
    defer c.g_value_unset(&v);
    return c.gst_iterator_filter(gst_bin_iterate_recurse(b), compareFactory, &v);
}
