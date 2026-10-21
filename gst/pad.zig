const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const gtype = @import("gtype.zig");
const object = @import("object.zig");
const info = @import("info.zig");
const padtemplate = @import("padtemplate.zig");
const flow = @import("padflow.zig");

comptime {
    @import("abi.zig").check(@This());
}

pub const HookList = extern struct {
    seq_id: c.gulong,
    bits: c.guint,
    hooks: [*c]c.GHook,
    dummy3: c.gpointer,
    finalize_hook: c.GHookFinalizeFunc,
    dummy: [2]c.gpointer,
};

pub const Pad = extern struct {
    object: c.GstObject,
    element_private: c.gpointer,
    padtemplate: [*c]c.GstPadTemplate,
    direction: c.GstPadDirection,
    stream_rec_lock: c.GRecMutex,
    task: [*c]c.GstTask,
    block_cond: c.GCond,
    probes: HookList,
    mode: c.GstPadMode,
    activatefunc: c.GstPadActivateFunction,
    activatedata: c.gpointer,
    activatenotify: c.GDestroyNotify,
    activatemodefunc: c.GstPadActivateModeFunction,
    activatemodedata: c.gpointer,
    activatemodenotify: c.GDestroyNotify,
    peer: [*c]Pad,
    linkfunc: c.GstPadLinkFunction,
    linkdata: c.gpointer,
    linknotify: c.GDestroyNotify,
    unlinkfunc: c.GstPadUnlinkFunction,
    unlinkdata: c.gpointer,
    unlinknotify: c.GDestroyNotify,
    chainfunc: c.GstPadChainFunction,
    chaindata: c.gpointer,
    chainnotify: c.GDestroyNotify,
    chainlistfunc: c.GstPadChainListFunction,
    chainlistdata: c.gpointer,
    chainlistnotify: c.GDestroyNotify,
    getrangefunc: c.GstPadGetRangeFunction,
    getrangedata: c.gpointer,
    getrangenotify: c.GDestroyNotify,
    eventfunc: c.GstPadEventFunction,
    eventdata: c.gpointer,
    eventnotify: c.GDestroyNotify,
    offset: c.gint64,
    queryfunc: c.GstPadQueryFunction,
    querydata: c.gpointer,
    querynotify: c.GDestroyNotify,
    iterintlinkfunc: c.GstPadIterIntLinkFunction,
    iterintlinkdata: c.gpointer,
    iterintlinknotify: c.GDestroyNotify,
    num_probes: c.gint,
    num_blocked: c.gint,
    priv: c.gpointer,
    ABI: extern union {
        reserved: [4]c.gpointer,
        abi: extern struct {
            last_flowret: c.GstFlowReturn,
            eventfullfunc: c.GstPadEventFullFunction,
        },
    },

    pub const Header = c.struct__GstPad;
};

pub const Raw = ?*c.GstPad;

pub fn h(p: anytype) Raw {
    return @ptrCast(@alignCast(p));
}

pub fn of(raw: anytype) [*c]Pad {
    return @ptrCast(@alignCast(raw));
}
const Obj = c.GstObject;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const NONE: u64 = std.math.maxInt(u64);
pub const SUCCESS_1: c.GstFlowReturn = c.GST_FLOW_CUSTOM_SUCCESS_1;
pub const ALL_BOTH_AND_FLUSH: c.GstPadProbeType = c.GST_PAD_PROBE_TYPE_ALL_BOTH | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH;
const HOOK_SHIFT = 4;

pub const PadEvent = extern struct {
    received: c.gboolean,
    order: c.guint,
    event: [*c]Event,
};

pub const Private = extern struct {
    events_cookie: c.guint,
    events: [*c]c.GArray,
    last_cookie: c.guint,
    using: c.gint,
    probe_cookie: c.guint,
    idle_running: c.gint,
    activation_cond: c.GCond,
    in_activation: c.gboolean,
};

const PROP_CAPS = 1;
const PROP_DIRECTION = 2;
const PROP_TEMPLATE = 3;
const PROP_OFFSET = 4;

var private_offset: c.gint = 0;
var parent_class: ?*c.GObjectClass = null;
var type_once: gtype.Once = .{};
var linked_signal: c.guint = 0;
var unlinked_signal: c.guint = 0;
pub var pspec_caps: [*c]c.GParamSpec = null;

const FlowName = struct { ret: c.GstFlowReturn, name: [:0]const u8 };

const flows = [_]FlowName{
    .{ .ret = c.GST_FLOW_CUSTOM_SUCCESS, .name = "custom-success" },
    .{ .ret = c.GST_FLOW_OK, .name = "ok" },
    .{ .ret = c.GST_FLOW_NOT_LINKED, .name = "not-linked" },
    .{ .ret = c.GST_FLOW_FLUSHING, .name = "flushing" },
    .{ .ret = c.GST_FLOW_EOS, .name = "eos" },
    .{ .ret = c.GST_FLOW_NOT_NEGOTIATED, .name = "not-negotiated" },
    .{ .ret = c.GST_FLOW_ERROR, .name = "error" },
    .{ .ret = c.GST_FLOW_NOT_SUPPORTED, .name = "not-supported" },
    .{ .ret = c.GST_FLOW_CUSTOM_ERROR, .name = "custom-error" },
};

var flow_quarks: [flows.len]c.GQuark = .{0} ** flows.len;

pub fn priv(p: anytype) *Private {
    const base: [*]u8 = @ptrCast(@constCast(p));
    return @ptrCast(@alignCast(base + @as(usize, @bitCast(@as(isize, private_offset)))));
}

pub fn isPad(p: anytype) bool {
    return gtype.instanceOf(p, gst_pad_get_type());
}

pub fn flags(p: [*c]Pad) *c.guint32 {
    return &p[0].object.flags;
}

pub fn has(p: [*c]Pad, f: c.guint) bool {
    return p[0].object.flags & f != 0;
}

pub fn set(p: [*c]Pad, f: c.guint) void {
    p[0].object.flags |= f;
}

pub fn clear(p: [*c]Pad, f: c.guint) void {
    p[0].object.flags &= ~@as(c.guint32, f);
}

pub fn isSrc(p: [*c]Pad) bool {
    return p[0].direction == c.GST_PAD_SRC;
}

pub fn isSink(p: [*c]Pad) bool {
    return p[0].direction == c.GST_PAD_SINK;
}

pub fn lock(p: anytype) void {
    object.lock(p);
}

pub fn unlock(p: anytype) void {
    object.unlock(p);
}

pub fn streamLock(p: [*c]Pad) void {
    c.g_rec_mutex_lock(&p[0].stream_rec_lock);
}

pub fn streamUnlock(p: [*c]Pad) void {
    c.g_rec_mutex_unlock(&p[0].stream_rec_lock);
}

pub fn blockWait(p: [*c]Pad) void {
    c.g_cond_wait(&p[0].block_cond, &p[0].object.lock);
}

pub fn blockBroadcast(p: [*c]Pad) void {
    c.g_cond_broadcast(&p[0].block_cond);
}

pub fn lastFlow(p: [*c]Pad) *c.GstFlowReturn {
    return @ptrCast(&p[0].ABI.abi.last_flowret);
}

pub fn parentOf(p: anytype) [*c]Obj {
    return object.of(p).parent;
}

var element_type: c.GType = 0;

pub fn elementType() c.GType {
    if (element_type == 0) element_type = gtype.weakType("gst_element_get_type");
    return element_type;
}

pub fn isElement(p: anytype) bool {
    const t = elementType();
    return t != 0 and gtype.instanceOf(p, t);
}

var post_fn: ?*const fn ([*c]c.GstElement, [*c]c.GstMessage) callconv(.c) c.gboolean = null;

pub fn post(el: [*c]c.GstElement, msg: [*c]c.GstMessage) void {
    if (post_fn == null) post_fn = gtype.lookup(?*const fn ([*c]c.GstElement, [*c]c.GstMessage) callconv(.c) c.gboolean, "gst_element_post_message");
    if (post_fn) |f| {
        _ = f(el, msg);
    } else c.gst_mini_object_unref(@ptrCast(msg));
}

pub fn nameOf(o: [*c]Obj) [*c]const u8 {
    if (o == null) return "''";
    return if (o[0].name != null) o[0].name else "(NULL)";
}

pub fn parentName(p: [*c]Pad) [*c]const u8 {
    if (p == null or parentOf(p) == null) return "''";
    return nameOf(parentOf(p));
}

pub fn padName(p: [*c]Pad) [*c]const u8 {
    if (p == null) return "''";
    return nameOf(@ptrCast(p));
}

pub fn acquireParent(p: [*c]Pad, out: *[*c]Obj) bool {
    out.* = parentOf(p);
    if (out.* != null) {
        _ = c.gst_object_ref(out.*);
        return true;
    }
    return !has(p, c.GST_PAD_FLAG_NEED_PARENT);
}

pub fn releaseParent(parent: [*c]Obj) void {
    if (parent != null) c.gst_object_unref(parent);
}

pub fn events(p: [*c]Pad) []PadEvent {
    const a = priv(p).events;
    if (a[0].len == 0) return &.{};
    const base: [*]PadEvent = @ptrCast(@alignCast(a[0].data));
    return base[0..a[0].len];
}

pub fn eventKind(e: [*c]Event) c.GstEventType {
    return e[0].type;
}

pub fn order(t: c.GstEventType) c.guint {
    return c.gst_event_type_to_sticky_ordering(t);
}

pub export fn gst_flow_get_name(ret: c.GstFlowReturn) [*c]const u8 {
    const r = std.math.clamp(ret, c.GST_FLOW_CUSTOM_ERROR, c.GST_FLOW_CUSTOM_SUCCESS);
    for (flows) |f| if (f.ret == r) return f.name.ptr;
    return "unknown";
}

pub export fn gst_flow_to_quark(ret: c.GstFlowReturn) c.GQuark {
    const r = std.math.clamp(ret, c.GST_FLOW_CUSTOM_ERROR, c.GST_FLOW_CUSTOM_SUCCESS);
    for (flows, 0..) |f, i| if (f.ret == r) return flow_quarks[i];
    return 0;
}

pub export fn gst_pad_link_get_name(ret: c.GstPadLinkReturn) [*c]const u8 {
    return switch (ret) {
        c.GST_PAD_LINK_OK => "ok",
        c.GST_PAD_LINK_WRONG_HIERARCHY => "wrong hierarchy",
        c.GST_PAD_LINK_WAS_LINKED => "was linked",
        c.GST_PAD_LINK_WRONG_DIRECTION => "wrong direction",
        c.GST_PAD_LINK_NOFORMAT => "no common format",
        c.GST_PAD_LINK_NOSCHED => "incompatible scheduling",
        c.GST_PAD_LINK_REFUSED => "refused",
        else => blk: {
            check.unreachableAt("../gst/gstpad.c", 207, "gst_pad_link_get_name");
            break :blk "unknown";
        },
    };
}

pub export fn gst_pad_mode_get_name(mode: c.GstPadMode) [*c]const u8 {
    return switch (mode) {
        c.GST_PAD_MODE_NONE => "none",
        c.GST_PAD_MODE_PUSH => "push",
        c.GST_PAD_MODE_PULL => "pull",
        else => "unknown",
    };
}

pub export fn gst_pad_get_type() c.GType {
    return type_once.get(struct {
        fn f() c.GType {
            for (flows, 0..) |fl, i| flow_quarks[i] = c.g_quark_from_static_string(fl.name.ptr);
            _ = c.g_quark_from_static_string("buffer");
            _ = c.g_quark_from_static_string("bufferlist");
            _ = c.g_quark_from_static_string("event");
            const t = gtype.object(object.gst_object_get_type(), "GstPad", c.GstPadClass, Pad, classInit, instanceInit, 0);
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
    gc.get_property = getProperty;
    const t = @as(*c.GTypeClass, @ptrCast(@alignCast(klass))).g_type;
    const none: c.GType = 1 << c.G_TYPE_FUNDAMENTAL_SHIFT;
    linked_signal = c.g_signal_new("linked", t, c.G_SIGNAL_RUN_LAST, @offsetOf(c.GstPadClass, "linked"), null, null, null, none, @as(c.guint, 1), t);
    unlinked_signal = c.g_signal_new("unlinked", t, c.G_SIGNAL_RUN_LAST, @offsetOf(c.GstPadClass, "unlinked"), null, null, null, none, @as(c.guint, 1), t);
    const s = c.G_PARAM_STATIC_STRINGS;
    pspec_caps = c.g_param_spec_boxed("caps", "Caps", "The capabilities of the pad", c.gst_caps_get_type(), c.G_PARAM_READABLE | s);
    c.g_object_class_install_property(gc, PROP_CAPS, pspec_caps);
    c.g_object_class_install_property(gc, PROP_DIRECTION, c.g_param_spec_enum("direction", "Direction", "The direction of the pad", c.gst_pad_direction_get_type(), c.GST_PAD_UNKNOWN, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | s));
    c.g_object_class_install_property(gc, PROP_TEMPLATE, c.g_param_spec_object("template", "Template", "The GstPadTemplate of this pad", padtemplate.gst_pad_template_get_type(), c.G_PARAM_READWRITE | s));
    c.g_object_class_install_property(gc, PROP_OFFSET, c.g_param_spec_int64("offset", "Offset", "The running time offset of the pad", 0, std.math.maxInt(i64), 0, c.G_PARAM_READWRITE | s));
    @as(*c.GstObjectClass, @ptrCast(@alignCast(klass))).path_string_separator = ".";
    info._gst_debug_register_funcptr(@ptrCast(&activateDefault), "gst_pad_activate_default");
    info._gst_debug_register_funcptr(@ptrCast(&flow.gst_pad_event_default), "gst_pad_event_default");
    info._gst_debug_register_funcptr(@ptrCast(&flow.gst_pad_query_default), "gst_pad_query_default");
    info._gst_debug_register_funcptr(@ptrCast(&gst_pad_iterate_internal_links_default), "gst_pad_iterate_internal_links_default");
    info._gst_debug_register_funcptr(@ptrCast(&flow.chainListDefault), "gst_pad_chain_list_default");
}

fn instanceInit(instance: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]Pad = @ptrCast(@alignCast(instance));
    const d = priv(p);
    p[0].priv = @ptrCast(d);
    p[0].direction = c.GST_PAD_UNKNOWN;
    p[0].activatefunc = activateDefault;
    p[0].eventfunc = flow.gst_pad_event_default;
    p[0].queryfunc = flow.gst_pad_query_default;
    p[0].iterintlinkfunc = gst_pad_iterate_internal_links_default;
    p[0].chainlistfunc = flow.chainListDefault;
    set(p, c.GST_PAD_FLAG_FLUSHING);
    c.g_rec_mutex_init(&p[0].stream_rec_lock);
    c.g_cond_init(&p[0].block_cond);
    c.g_hook_list_init(@ptrCast(&p[0].probes), @sizeOf(c.GHook));
    d.events = c.g_array_sized_new(0, 1, @sizeOf(PadEvent), 16);
    d.last_cookie = std.math.maxInt(c.guint);
    c.g_cond_init(&d.activation_cond);
    lastFlow(p).* = c.GST_FLOW_FLUSHING;
}

pub fn removeEvents(p: [*c]Pad) void {
    var notify = false;
    for (events(p)) |*ev| {
        const e = ev.event;
        ev.event = null;
        if (e != null and eventKind(e) == c.GST_EVENT_CAPS) notify = true;
        c.gst_mini_object_unref(@ptrCast(e));
    }
    clear(p, c.GST_PAD_FLAG_PENDING_EVENTS);
    _ = c.g_array_set_size(priv(p).events, 0);
    priv(p).events_cookie +%= 1;
    if (notify) {
        unlock(p);
        c.g_object_notify_by_pspec(@ptrCast(p), pspec_caps);
        lock(p);
    }
}

pub fn findByType(p: [*c]Pad, t: c.GstEventType, idx_in: c.guint) ?*PadEvent {
    var idx = idx_in;
    const last = order(t);
    for (events(p)) |*ev| {
        if (ev.event == null) continue;
        if (eventKind(ev.event) == t) {
            if (idx == 0) return ev;
            idx -= 1;
        } else if (ev.order > last) break;
    }
    return null;
}

fn findEvent(p: [*c]Pad, e: [*c]Event) ?*PadEvent {
    const o = order(eventKind(e));
    for (events(p)) |*ev| {
        if (ev.event == e) return ev;
        if (ev.order > o) break;
    }
    return null;
}

pub fn removeByType(p: [*c]Pad, t: c.GstEventType) void {
    const last = order(t);
    var i: c.guint = 0;
    while (i < priv(p).events[0].len) {
        const ev = &events(p)[i];
        if (ev.event != null) {
            if (ev.order > last) break;
            if (eventKind(ev.event) == t) {
                c.gst_mini_object_unref(@ptrCast(ev.event));
                _ = c.g_array_remove_index(priv(p).events, i);
                priv(p).events_cookie +%= 1;
                continue;
            }
        }
        i += 1;
    }
}

pub fn scheduleEvents(src: [*c]Pad, sink: [*c]Pad) void {
    var pending = false;
    for (events(src)) |*ev| {
        if (ev.event == null) continue;
        if (sink == null or findEvent(sink, ev.event) == null) {
            ev.received = 0;
            pending = true;
        }
    }
    if (pending) set(src, c.GST_PAD_FLAG_PENDING_EVENTS);
}

pub const EventFn = *const fn (p: [*c]Pad, ev: *PadEvent, data: ?*anyopaque) bool;

pub fn eachEvent(p: [*c]Pad, func: EventFn, data: ?*anyopaque) void {
    const d = priv(p);
    restart: while (true) {
        var cookie = d.events_cookie;
        var i: c.guint = 0;
        while (i < d.events[0].len) {
            const ev = &events(p)[i];
            if (ev.event == null) {
                i += 1;
                continue;
            }
            var copy = PadEvent{ .order = ev.order, .event = @ptrCast(c.gst_mini_object_ref(@ptrCast(ev.event))), .received = ev.received };
            const keep = func(p, &copy, data);
            if (cookie != d.events_cookie) {
                if (copy.event != null) c.gst_mini_object_unref(@ptrCast(copy.event));
                continue :restart;
            }
            const cur = &events(p)[i];
            cur.received = copy.received;
            if (cur.event != copy.event) {
                if (copy.event == null) {
                    c.gst_mini_object_unref(@ptrCast(cur.event));
                    _ = c.g_array_remove_index(d.events, i);
                    d.events_cookie +%= 1;
                    cookie = d.events_cookie;
                    continue;
                }
                _ = c.gst_mini_object_take(@ptrCast(&cur.event), @ptrCast(copy.event));
            } else c.gst_mini_object_unref(@ptrCast(copy.event));
            if (!keep) return;
            i += 1;
        }
        return;
    }
}

pub fn offsetEvent(e_in: [*c]Event, upstream: bool, delta: i64) [*c]Event {
    var e = e_in;
    if (eventKind(e) == c.GST_EVENT_SEGMENT) {
        var seg: c.GstSegment = undefined;
        c.gst_event_copy_segment(e, &seg);
        const seqnum = c.gst_event_get_seqnum(e);
        c.gst_mini_object_unref(@ptrCast(e));
        _ = c.gst_segment_offset_running_time(&seg, seg.format, delta);
        e = c.gst_event_new_segment(&seg);
        c.gst_event_set_seqnum(e, seqnum);
    }
    e = c.gst_event_make_writable(e);
    var off = c.gst_event_get_running_time_offset(e);
    if (upstream) off -%= delta else off +%= delta;
    c.gst_event_set_running_time_offset(e, off);
    return e;
}

pub fn applyOffset(p: [*c]Pad, e: [*c]Event, upstream: bool) [*c]Event {
    if (p[0].offset != 0) return offsetEvent(e, upstream, p[0].offset);
    return e;
}

pub fn currentCaps(p: [*c]Pad) [*c]Caps {
    const ev = findByType(p, c.GST_EVENT_CAPS, 0) orelse return null;
    if (ev.event == null) return null;
    var caps: [*c]Caps = null;
    c.gst_event_parse_caps(ev.event, &caps);
    return caps;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    const peer = gst_pad_get_peer(p);
    if (peer != null) {
        if (isSrc(p)) _ = gst_pad_unlink(p, peer) else _ = gst_pad_unlink(peer, p);
        c.gst_object_unref(peer);
    }
    setTemplate(p, null);
    lock(p);
    removeEvents(p);
    c.g_hook_list_clear(@ptrCast(&p[0].probes));
    unlock(p);
    parent_class.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    if (p[0].task != null) {
        _ = c.gst_task_join(p[0].task);
        const t = p[0].task;
        p[0].task = null;
        c.gst_object_unref(t);
    }
    if (p[0].activatenotify) |n| n(p[0].activatedata);
    if (p[0].activatemodenotify) |n| n(p[0].activatemodedata);
    if (p[0].linknotify) |n| n(p[0].linkdata);
    if (p[0].unlinknotify) |n| n(p[0].unlinkdata);
    if (p[0].chainnotify) |n| n(p[0].chaindata);
    if (p[0].chainlistnotify) |n| n(p[0].chainlistdata);
    if (p[0].getrangenotify) |n| n(p[0].getrangedata);
    if (p[0].eventnotify) |n| n(p[0].eventdata);
    if (p[0].querynotify) |n| n(p[0].querydata);
    if (p[0].iterintlinknotify) |n| n(p[0].iterintlinkdata);
    c.g_rec_mutex_clear(&p[0].stream_rec_lock);
    c.g_cond_clear(&p[0].block_cond);
    c.g_cond_clear(&priv(p).activation_cond);
    _ = c.g_array_free(priv(p).events, 1);
    parent_class.?.finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (!check.that(isPad(o), "gst_pad_set_property", "GST_IS_PAD (object)")) return;
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_DIRECTION => p[0].direction = @intCast(c.g_value_get_enum(v)),
        PROP_TEMPLATE => setTemplate(p, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_OFFSET => gst_pad_set_offset(p, c.g_value_get_int64(v)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (!check.that(isPad(o), "gst_pad_get_property", "GST_IS_PAD (object)")) return;
    const p: [*c]Pad = @ptrCast(@alignCast(o));
    switch (id) {
        PROP_CAPS => {
            lock(p);
            c.g_value_set_boxed(v, currentCaps(p));
            unlock(p);
        },
        PROP_DIRECTION => c.g_value_set_enum(v, @intCast(p[0].direction)),
        PROP_TEMPLATE => c.g_value_set_object(v, p[0].padtemplate),
        PROP_OFFSET => c.g_value_set_int64(v, gst_pad_get_offset(p)),
        else => object.warnBadProperty(o, id, pspec),
    }
}

pub export fn gst_pad_new(name: [*c]const u8, dir: c.GstPadDirection) [*c]Pad {
    return @ptrCast(@alignCast(c.g_object_new(gst_pad_get_type(), "name", name, "direction", dir, @as([*c]const u8, null))));
}

pub export fn gst_pad_new_from_template(templ: [*c]c.GstPadTemplate, name: [*c]const u8) [*c]Pad {
    const t = if (templ[0].ABI.abi.gtype == (1 << c.G_TYPE_FUNDAMENTAL_SHIFT)) gst_pad_get_type() else templ[0].ABI.abi.gtype;
    if (!check.that(padtemplate.isTemplate(templ), "gst_pad_new_from_template", "GST_IS_PAD_TEMPLATE (templ)")) return null;
    return @ptrCast(@alignCast(c.g_object_new(t, "name", name, "direction", templ[0].direction, "template", templ, @as([*c]const u8, null))));
}

pub export fn gst_pad_new_from_static_template(templ: [*c]c.GstStaticPadTemplate, name: [*c]const u8) [*c]Pad {
    const t = padtemplate.gst_static_pad_template_get(templ);
    const p = gst_pad_new_from_template(t, name);
    c.gst_object_unref(t);
    return p;
}

pub export fn gst_pad_get_direction(p: [*c]Pad) c.GstPadDirection {
    if (!check.that(isPad(p), "gst_pad_get_direction", "GST_IS_PAD (pad)")) return c.GST_PAD_UNKNOWN;
    return p[0].direction;
}

fn activateDefault(raw: Raw, parent: [*c]Obj) callconv(.c) c.gboolean {
    const p = of(raw);
    if (!check.that(isPad(p), "gst_pad_activate_default", "GST_IS_PAD (pad)")) return 0;
    return @intFromBool(activateMode(p, parent, c.GST_PAD_MODE_PUSH, true));
}

fn waitActivation(p: [*c]Pad) void {
    while (priv(p).in_activation != 0) c.g_cond_wait(&priv(p).activation_cond, &p[0].object.lock);
}

fn preActivate(p: [*c]Pad, mode: c.GstPadMode) bool {
    lock(p);
    waitActivation(p);
    if (mode == p[0].mode) {
        unlock(p);
        return false;
    }
    priv(p).in_activation = 1;
    if (mode == c.GST_PAD_MODE_NONE) {
        set(p, c.GST_PAD_FLAG_FLUSHING);
        lastFlow(p).* = c.GST_FLOW_FLUSHING;
        p[0].mode = mode;
        blockBroadcast(p);
        unlock(p);
        return true;
    }
    clear(p, c.GST_PAD_FLAG_FLUSHING);
    lastFlow(p).* = c.GST_FLOW_OK;
    p[0].mode = mode;
    if (isSink(p) and p[0].peer != null) {
        const peer = p[0].peer;
        _ = c.gst_object_ref(peer);
        unlock(p);
        lock(peer);
        scheduleEvents(peer, null);
        unlock(peer);
        c.gst_object_unref(peer);
    } else unlock(p);
    return true;
}

fn postActivate(p: [*c]Pad, mode: c.GstPadMode) void {
    lock(p);
    priv(p).in_activation = 0;
    c.g_cond_broadcast(&priv(p).activation_cond);
    unlock(p);
    if (mode != c.GST_PAD_MODE_NONE) return;
    streamLock(p);
    lock(p);
    removeEvents(p);
    unlock(p);
    streamUnlock(p);
}

pub export fn gst_pad_set_active(p: [*c]Pad, active: c.gboolean) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_set_active", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    const old = p[0].mode;
    var parent: [*c]Obj = null;
    if (!acquireParent(p, &parent)) {
        unlock(p);
        return 0;
    }
    unlock(p);
    var ok = true;
    if (active != 0) {
        if (old == c.GST_PAD_MODE_NONE) {
            ok = p[0].activatefunc.?(h(p), parent) != 0;
            if (ok) lastFlow(p).* = c.GST_FLOW_OK;
        }
    } else if (old != c.GST_PAD_MODE_NONE) {
        ok = activateMode(p, parent, old, false);
        if (ok) lastFlow(p).* = c.GST_FLOW_FLUSHING;
    }
    releaseParent(parent);
    if (ok) return 1;
    if (active == 0) c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "Failed to deactivate pad %s:%s, very bad", parentName(p), padName(p));
    return 0;
}

fn activateMode(p: [*c]Pad, parent: [*c]Obj, mode: c.GstPadMode, active: bool) bool {
    lock(p);
    var old = p[0].mode;
    const dir = p[0].direction;
    unlock(p);
    const new = if (active) mode else c.GST_PAD_MODE_NONE;
    if (old != new) {
        if (active and old != mode and old != c.GST_PAD_MODE_NONE) {
            if (!activateMode(p, parent, old, false)) return false;
            old = c.GST_PAD_MODE_NONE;
        }
        if (mode == c.GST_PAD_MODE_PULL) {
            if (dir == c.GST_PAD_SINK) {
                const peer = gst_pad_get_peer(p);
                if (peer != null) {
                    const ok = gst_pad_activate_mode(peer, mode, @intFromBool(active)) != 0;
                    if (!ok) {
                        lock(peer);
                        unlock(peer);
                    }
                    c.gst_object_unref(peer);
                    if (!ok) return false;
                } else if (active) return false;
            } else if (p[0].getrangefunc == null) {
                return activationFailed(p, old);
            }
        }
        if (active) {
            lock(p);
            set(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
            unlock(p);
        }
        if (preActivate(p, new)) {
            if (p[0].activatemodefunc) |f| {
                if (f(h(p), parent, mode, @intFromBool(active)) == 0) return activationFailed(p, old);
            }
            postActivate(p, new);
        }
    }
    if (!active) {
        lock(p);
        clear(p, c.GST_PAD_FLAG_NEED_RECONFIGURE | c.GST_PAD_FLAG_EOS);
        unlock(p);
    }
    return true;
}

fn activationFailed(p: [*c]Pad, old: c.GstPadMode) bool {
    lock(p);
    set(p, c.GST_PAD_FLAG_FLUSHING);
    p[0].mode = old;
    priv(p).in_activation = 0;
    c.g_cond_broadcast(&priv(p).activation_cond);
    unlock(p);
    return false;
}

pub export fn gst_pad_activate_mode(p: [*c]Pad, mode: c.GstPadMode, active: c.gboolean) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_activate_mode", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    const new = if (active != 0) mode else c.GST_PAD_MODE_NONE;
    if (p[0].mode == new) {
        unlock(p);
        return 1;
    }
    var parent: [*c]Obj = null;
    if (!acquireParent(p, &parent)) {
        unlock(p);
        return 0;
    }
    unlock(p);
    const r = activateMode(p, parent, mode, active != 0);
    releaseParent(parent);
    return @intFromBool(r);
}

pub export fn gst_pad_is_active(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_is_active", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return @intFromBool(p[0].mode != c.GST_PAD_MODE_NONE);
}

pub fn cleanupHook(p: [*c]Pad, hook: [*c]c.GHook) void {
    if (hook[0].hook_id == 0 or hook[0].flags & c.G_HOOK_FLAG_ACTIVE == 0) return;
    const kind = hook[0].flags >> HOOK_SHIFT;
    if (kind & c.GST_PAD_PROBE_TYPE_BLOCKING != 0) {
        p[0].num_blocked -= 1;
        blockBroadcast(p);
        if (p[0].num_blocked == 0) clear(p, c.GST_PAD_FLAG_BLOCKED);
    }
    c.g_hook_destroy_link(@ptrCast(&p[0].probes), hook);
    p[0].num_probes -= 1;
}

pub export fn gst_pad_add_probe(p: [*c]Pad, mask_in: c.GstPadProbeType, callback: c.GstPadProbeCallback, data: c.gpointer, destroy: c.GDestroyNotify) c.gulong {
    if (!check.that(isPad(p), "gst_pad_add_probe", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(mask_in != 0, "gst_pad_add_probe", "mask != 0")) return 0;
    var mask = mask_in;
    lock(p);
    const hook = c.g_hook_alloc(@ptrCast(&p[0].probes));
    if (mask & ALL_BOTH_AND_FLUSH == 0) mask |= c.GST_PAD_PROBE_TYPE_ALL_BOTH;
    if (mask & c.GST_PAD_PROBE_TYPE_SCHEDULING == 0) mask |= c.GST_PAD_PROBE_TYPE_SCHEDULING;
    hook[0].flags |= mask << HOOK_SHIFT;
    hook[0].func = @ptrCast(@constCast(callback));
    hook[0].data = data;
    hook[0].destroy = destroy;
    c.g_hook_insert_before(@ptrCast(&p[0].probes), null, hook);
    p[0].num_probes += 1;
    priv(p).probe_cookie +%= 1;
    var res = hook[0].hook_id;
    if (mask & c.GST_PAD_PROBE_TYPE_BLOCKING != 0) {
        p[0].num_blocked += 1;
        set(p, c.GST_PAD_FLAG_BLOCKED);
        blockBroadcast(p);
    }
    const cb = callback orelse {
        unlock(p);
        return res;
    };
    if (mask & c.GST_PAD_PROBE_TYPE_IDLE == 0 or priv(p).using > 0) {
        unlock(p);
        return res;
    }
    var pi = std.mem.zeroes(c.GstPadProbeInfo);
    pi.type = c.GST_PAD_PROBE_TYPE_IDLE;
    pi.id = res;
    _ = c.gst_object_ref(p);
    priv(p).idle_running += 1;
    _ = c.g_hook_ref(@ptrCast(&p[0].probes), hook);
    unlock(p);
    const ret = cb(h(p), &pi, data);
    lock(p);
    if (ret == c.GST_PAD_PROBE_REMOVE) {
        cleanupHook(p, hook);
        res = 0;
    }
    c.g_hook_unref(@ptrCast(&p[0].probes), hook);
    priv(p).idle_running -= 1;
    if (priv(p).idle_running == 0) blockBroadcast(p);
    unlock(p);
    c.gst_object_unref(p);
    return res;
}

pub export fn gst_pad_remove_probe(p: [*c]Pad, id: c.gulong) void {
    if (!check.that(isPad(p), "gst_pad_remove_probe", "GST_IS_PAD (pad)")) return;
    lock(p);
    const hook = c.g_hook_get(@ptrCast(&p[0].probes), id);
    if (hook == null) {
        unlock(p);
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: pad `%p' has no probe with id `%lu'", "../gst/gstpad.c:1595", p, id);
        return;
    }
    cleanupHook(p, hook);
    unlock(p);
}

fn flagCheck(comptime f: []const u8, p: [*c]Pad, comptime fl: c.guint) c.gboolean {
    if (!check.that(isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return @intFromBool(has(p, fl));
}

pub export fn gst_pad_is_blocked(p: [*c]Pad) c.gboolean {
    return flagCheck("gst_pad_is_blocked", p, c.GST_PAD_FLAG_BLOCKED);
}

pub export fn gst_pad_is_blocking(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_is_blocking", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return @intFromBool(has(p, c.GST_PAD_FLAG_BLOCKING) and !has(p, c.GST_PAD_FLAG_FLUSHING));
}

pub export fn gst_pad_needs_reconfigure(p: [*c]Pad) c.gboolean {
    return flagCheck("gst_pad_needs_reconfigure", p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
}

pub export fn gst_pad_check_reconfigure(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_check_reconfigure", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    const r = has(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
    if (r) clear(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
    return @intFromBool(r);
}

pub export fn gst_pad_mark_reconfigure(p: [*c]Pad) void {
    if (!check.that(isPad(p), "gst_pad_mark_reconfigure", "GST_IS_PAD (pad)")) return;
    lock(p);
    set(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
    unlock(p);
}

fn swap(comptime F: type, slot: anytype, data: anytype, notify: anytype, func: F, new_data: c.gpointer, new_notify: c.GDestroyNotify) void {
    if (notify.*) |n| n(data.*);
    slot.* = func;
    data.* = new_data;
    notify.* = new_notify;
}

pub export fn gst_pad_set_activate_function_full(p: [*c]Pad, f: c.GstPadActivateFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_activate_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadActivateFunction, &p[0].activatefunc, &p[0].activatedata, &p[0].activatenotify, f, data, notify);
}

pub export fn gst_pad_set_activatemode_function_full(p: [*c]Pad, f: c.GstPadActivateModeFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_activatemode_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadActivateModeFunction, &p[0].activatemodefunc, &p[0].activatemodedata, &p[0].activatemodenotify, f, data, notify);
}

pub export fn gst_pad_set_chain_function_full(p: [*c]Pad, f: c.GstPadChainFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_chain_function_full", "GST_IS_PAD (pad)")) return;
    if (!check.that(isSink(p), "gst_pad_set_chain_function_full", "GST_PAD_IS_SINK (pad)")) return;
    swap(c.GstPadChainFunction, &p[0].chainfunc, &p[0].chaindata, &p[0].chainnotify, f, data, notify);
}

pub export fn gst_pad_set_chain_list_function_full(p: [*c]Pad, f: c.GstPadChainListFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_chain_list_function_full", "GST_IS_PAD (pad)")) return;
    if (!check.that(isSink(p), "gst_pad_set_chain_list_function_full", "GST_PAD_IS_SINK (pad)")) return;
    swap(c.GstPadChainListFunction, &p[0].chainlistfunc, &p[0].chainlistdata, &p[0].chainlistnotify, f, data, notify);
}

pub export fn gst_pad_set_getrange_function_full(p: [*c]Pad, f: c.GstPadGetRangeFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_getrange_function_full", "GST_IS_PAD (pad)")) return;
    if (!check.that(isSrc(p), "gst_pad_set_getrange_function_full", "GST_PAD_IS_SRC (pad)")) return;
    swap(c.GstPadGetRangeFunction, &p[0].getrangefunc, &p[0].getrangedata, &p[0].getrangenotify, f, data, notify);
}

pub export fn gst_pad_set_event_function_full(p: [*c]Pad, f: c.GstPadEventFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_event_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadEventFunction, &p[0].eventfunc, &p[0].eventdata, &p[0].eventnotify, f, data, notify);
}

fn eventWrap(raw: Raw, parent: [*c]Obj, e: [*c]Event) callconv(.c) c.gboolean {
    return @intFromBool(of(raw)[0].ABI.abi.eventfullfunc.?(raw, parent, e) == c.GST_FLOW_OK);
}

pub export fn gst_pad_set_event_full_function_full(p: [*c]Pad, f: c.GstPadEventFullFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_event_full_function_full", "GST_IS_PAD (pad)")) return;
    if (p[0].eventnotify) |n| n(p[0].eventdata);
    p[0].ABI.abi.eventfullfunc = f;
    p[0].eventfunc = eventWrap;
    p[0].eventdata = data;
    p[0].eventnotify = notify;
}

pub export fn gst_pad_set_query_function_full(p: [*c]Pad, f: c.GstPadQueryFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_query_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadQueryFunction, &p[0].queryfunc, &p[0].querydata, &p[0].querynotify, f, data, notify);
}

pub export fn gst_pad_set_iterate_internal_links_function_full(p: [*c]Pad, f: c.GstPadIterIntLinkFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_iterate_internal_links_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadIterIntLinkFunction, &p[0].iterintlinkfunc, &p[0].iterintlinkdata, &p[0].iterintlinknotify, f, data, notify);
}

pub export fn gst_pad_set_link_function_full(p: [*c]Pad, f: c.GstPadLinkFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_link_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadLinkFunction, &p[0].linkfunc, &p[0].linkdata, &p[0].linknotify, f, data, notify);
}

pub export fn gst_pad_set_unlink_function_full(p: [*c]Pad, f: c.GstPadUnlinkFunction, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isPad(p), "gst_pad_set_unlink_function_full", "GST_IS_PAD (pad)")) return;
    swap(c.GstPadUnlinkFunction, &p[0].unlinkfunc, &p[0].unlinkdata, &p[0].unlinknotify, f, data, notify);
}

fn structureChange(sink: [*c]Pad, kind: c.GstStructureChangeType, parent: [*c]c.GstElement, busy: bool) void {
    post(parent, c.gst_message_new_structure_change(@ptrCast(sink), kind, parent, @intFromBool(busy)));
}

fn linkParent(src: [*c]Pad, sink: [*c]Pad, kind: c.GstStructureChangeType) [*c]c.GstElement {
    const parent = c.gst_object_get_parent(@ptrCast(src));
    if (parent == null) return null;
    if (!isElement(parent)) {
        c.gst_object_unref(parent);
        return null;
    }
    structureChange(sink, kind, @ptrCast(parent), true);
    return @ptrCast(parent);
}

fn callUnlink(p: [*c]Pad) void {
    const f = p[0].unlinkfunc orelse return;
    var parent: [*c]Obj = null;
    if (!acquireParent(p, &parent)) return;
    f(h(p), parent);
    releaseParent(parent);
}

pub export fn gst_pad_unlink(src: [*c]Pad, sink: [*c]Pad) c.gboolean {
    const f = "gst_pad_unlink";
    if (!check.that(isPad(src), f, "GST_IS_PAD (srcpad)")) return 0;
    if (!check.that(isSrc(src), f, "GST_PAD_IS_SRC (srcpad)")) return 0;
    if (!check.that(isPad(sink), f, "GST_IS_PAD (sinkpad)")) return 0;
    if (!check.that(isSink(sink), f, "GST_PAD_IS_SINK (sinkpad)")) return 0;
    const parent = linkParent(src, sink, c.GST_STRUCTURE_CHANGE_TYPE_PAD_UNLINK);
    var result: c.gboolean = 0;
    lock(src);
    lock(sink);
    if (src[0].peer == sink) {
        callUnlink(src);
        callUnlink(sink);
        src[0].peer = null;
        sink[0].peer = null;
        unlock(sink);
        unlock(src);
        c.g_signal_emit(src, unlinked_signal, 0, sink);
        c.g_signal_emit(sink, unlinked_signal, 0, src);
        result = 1;
    } else {
        unlock(sink);
        unlock(src);
    }
    if (parent != null) {
        structureChange(sink, c.GST_STRUCTURE_CHANGE_TYPE_PAD_UNLINK, parent, false);
        c.gst_object_unref(parent);
    }
    return result;
}

pub export fn gst_pad_is_linked(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_is_linked", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return @intFromBool(p[0].peer != null);
}

fn compatible(src: [*c]Pad, sink: [*c]Pad, fl: c.GstPadLinkCheck) bool {
    if (fl & (c.GST_PAD_LINK_CHECK_CAPS | c.GST_PAD_LINK_CHECK_TEMPLATE_CAPS) == 0) return true;
    var a: [*c]Caps = null;
    var b: [*c]Caps = null;
    if (fl & c.GST_PAD_LINK_CHECK_CAPS != 0) {
        unlock(sink);
        unlock(src);
        a = flow.gst_pad_query_caps(src, null);
        b = flow.gst_pad_query_caps(sink, null);
        lock(src);
        lock(sink);
    } else {
        if (src[0].padtemplate == null or sink[0].padtemplate == null) return true;
        a = c.gst_caps_ref(src[0].padtemplate[0].caps);
        b = c.gst_caps_ref(sink[0].padtemplate[0].caps);
    }
    if (a == null or b == null) {
        if (a != null) c.gst_caps_unref(a);
        if (b != null) c.gst_caps_unref(b);
        return false;
    }
    const r = c.gst_caps_can_intersect(a, b) != 0;
    c.gst_caps_unref(a);
    c.gst_caps_unref(b);
    return r;
}

fn hierarchyOk(src: [*c]Pad, sink: [*c]Pad) bool {
    const a = parentOf(src);
    const b = parentOf(sink);
    if (a == null or b == null) return true;
    if (!isElement(a) or !isElement(b)) return true;
    if (a == b) return false;
    return parentOf(a) == parentOf(b);
}

fn relations(src: [*c]Pad, sink: [*c]Pad, fl: c.GstPadLinkCheck) c.GstPadLinkReturn {
    if (src[0].peer != null or sink[0].peer != null) return c.GST_PAD_LINK_WAS_LINKED;
    if (fl & c.GST_PAD_LINK_CHECK_HIERARCHY != 0 and !hierarchyOk(src, sink)) return c.GST_PAD_LINK_WRONG_HIERARCHY;
    return c.GST_PAD_LINK_OK;
}

fn prepare(src: [*c]Pad, sink: [*c]Pad, fl: c.GstPadLinkCheck) c.GstPadLinkReturn {
    lock(src);
    lock(sink);
    var r = relations(src, sink, fl);
    if (r == c.GST_PAD_LINK_OK and !compatible(src, sink, fl)) r = c.GST_PAD_LINK_NOFORMAT;
    if (r == c.GST_PAD_LINK_OK) r = relations(src, sink, fl);
    if (r != c.GST_PAD_LINK_OK) {
        unlock(sink);
        unlock(src);
    }
    return r;
}

pub export fn gst_pad_can_link(src: [*c]Pad, sink: [*c]Pad) c.gboolean {
    if (!check.that(isPad(src), "gst_pad_can_link", "GST_IS_PAD (srcpad)")) return 0;
    if (!check.that(isPad(sink), "gst_pad_can_link", "GST_IS_PAD (sinkpad)")) return 0;
    const r = prepare(src, sink, c.GST_PAD_LINK_CHECK_DEFAULT);
    if (r != c.GST_PAD_LINK_OK) return 0;
    unlock(src);
    unlock(sink);
    return 1;
}

pub export fn gst_pad_link_full(src: [*c]Pad, sink: [*c]Pad, fl: c.GstPadLinkCheck) c.GstPadLinkReturn {
    const f = "gst_pad_link_full";
    if (!check.that(isPad(src), f, "GST_IS_PAD (srcpad)")) return c.GST_PAD_LINK_REFUSED;
    if (!check.that(isSrc(src), f, "GST_PAD_IS_SRC (srcpad)")) return c.GST_PAD_LINK_WRONG_DIRECTION;
    if (!check.that(isPad(sink), f, "GST_IS_PAD (sinkpad)")) return c.GST_PAD_LINK_REFUSED;
    if (!check.that(isSink(sink), f, "GST_PAD_IS_SINK (sinkpad)")) return c.GST_PAD_LINK_WRONG_DIRECTION;
    const parent = linkParent(src, sink, c.GST_STRUCTURE_CHANGE_TYPE_PAD_LINK);
    defer if (parent != null) {
        structureChange(sink, c.GST_STRUCTURE_CHANGE_TYPE_PAD_LINK, parent, false);
        c.gst_object_unref(parent);
    };
    var result = prepare(src, sink, fl);
    if (result != c.GST_PAD_LINK_OK) return result;
    src[0].peer = sink;
    sink[0].peer = src;
    scheduleEvents(src, sink);
    const srcfunc = src[0].linkfunc;
    const sinkfunc = sink[0].linkfunc;
    if (srcfunc != null or sinkfunc != null) {
        unlock(sink);
        unlock(src);
        var tmp: [*c]Obj = null;
        if (srcfunc) |lf| {
            if (acquireParent(src, &tmp)) {
                result = lf(h(src), tmp, h(sink));
                releaseParent(tmp);
            }
        } else if (sinkfunc) |lf| {
            if (acquireParent(sink, &tmp)) {
                result = lf(h(sink), tmp, h(src));
                releaseParent(tmp);
            }
        }
        lock(src);
        lock(sink);
        if (src[0].peer != sink or sink[0].peer != src) {
            unlock(sink);
            unlock(src);
            return c.GST_PAD_LINK_WAS_LINKED;
        }
        if (result != c.GST_PAD_LINK_OK) {
            src[0].peer = null;
            sink[0].peer = null;
            unlock(sink);
            unlock(src);
            return result;
        }
    }
    unlock(sink);
    unlock(src);
    c.g_signal_emit(src, linked_signal, 0, sink);
    c.g_signal_emit(sink, linked_signal, 0, src);
    if (fl & c.GST_PAD_LINK_CHECK_NO_RECONFIGURE == 0) _ = flow.gst_pad_send_event(src, c.gst_event_new_reconfigure());
    return result;
}

pub export fn gst_pad_link(src: [*c]Pad, sink: [*c]Pad) c.GstPadLinkReturn {
    return gst_pad_link_full(src, sink, c.GST_PAD_LINK_CHECK_DEFAULT);
}

fn setTemplate(p: [*c]Pad, templ: [*c]c.GstPadTemplate) void {
    lock(p);
    _ = object.gst_object_replace(@ptrCast(&p[0].padtemplate), @ptrCast(templ));
    unlock(p);
    if (templ != null) padtemplate.gst_pad_template_pad_created(templ, h(p));
}

pub export fn gst_pad_get_pad_template(p: [*c]Pad) [*c]c.GstPadTemplate {
    if (!check.that(isPad(p), "gst_pad_get_pad_template", "GST_IS_PAD (pad)")) return null;
    const t = p[0].padtemplate;
    return if (t != null) @ptrCast(@alignCast(c.gst_object_ref(t))) else null;
}

pub export fn gst_pad_has_current_caps(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_has_current_caps", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return @intFromBool(currentCaps(p) != null);
}

pub export fn gst_pad_get_current_caps(p: [*c]Pad) [*c]Caps {
    if (!check.that(isPad(p), "gst_pad_get_current_caps", "GST_IS_PAD (pad)")) return null;
    lock(p);
    defer unlock(p);
    const caps = currentCaps(p);
    if (caps != null) _ = c.gst_caps_ref(caps);
    return caps;
}

pub export fn gst_pad_get_pad_template_caps(p: [*c]Pad) [*c]Caps {
    if (!check.that(isPad(p), "gst_pad_get_pad_template_caps", "GST_IS_PAD (pad)")) return null;
    if (p[0].padtemplate != null) return padtemplate.gst_pad_template_get_caps(p[0].padtemplate);
    return c.gst_caps_ref(c._gst_caps_any);
}

pub export fn gst_pad_get_peer(p: [*c]Pad) [*c]Pad {
    if (!check.that(isPad(p), "gst_pad_get_peer", "GST_IS_PAD (pad)")) return null;
    lock(p);
    defer unlock(p);
    const peer = p[0].peer;
    if (peer != null) _ = c.gst_object_ref(peer);
    return peer;
}

pub export fn gst_pad_get_allowed_caps(p: [*c]Pad) [*c]Caps {
    if (!check.that(isPad(p), "gst_pad_get_allowed_caps", "GST_IS_PAD (pad)")) return null;
    lock(p);
    if (p[0].peer == null) {
        unlock(p);
        return null;
    }
    unlock(p);
    const mine = flow.gst_pad_query_caps(p, null);
    const q = c.gst_query_new_caps(mine);
    var caps: [*c]Caps = null;
    if (flow.gst_pad_peer_query(p, q) != 0) {
        c.gst_query_parse_caps_result(q, &caps);
        if (caps == null) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s: runtime check failed: (%s)", "../gst/gstpad.c:2950", "caps != NULL");
        } else _ = c.gst_caps_ref(caps);
    }
    c.gst_query_unref(q);
    c.gst_caps_unref(mine);
    return caps;
}

pub export fn gst_pad_get_single_internal_link(p: [*c]Pad) [*c]Pad {
    if (!check.that(isPad(p), "gst_pad_get_single_internal_link", "GST_IS_PAD (pad)")) return null;
    const it = gst_pad_iterate_internal_links(p);
    if (it == null) return null;
    var item = std.mem.zeroes(c.GValue);
    var ret: [*c]Pad = null;
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                if (ret == null) {
                    ret = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
                } else {
                    c.gst_object_unref(ret);
                    ret = null;
                    done = true;
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                if (ret != null) c.gst_object_unref(ret);
                ret = null;
                c.gst_iterator_resync(it);
            },
            c.GST_ITERATOR_ERROR => return null,
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    return ret;
}

pub export fn gst_pad_iterate_internal_links_default(raw: Raw, parent: [*c]Obj) [*c]c.GstIterator {
    const p = of(raw);
    if (!check.that(isPad(p), "gst_pad_iterate_internal_links_default", "GST_IS_PAD (pad)")) return null;
    var el: [*c]c.GstElement = null;
    if (parent != null and isElement(parent)) {
        el = @ptrCast(@alignCast(c.gst_object_ref(parent)));
    } else {
        lock(p);
        const pp = parentOf(p);
        if (pp == null or !isElement(pp)) {
            unlock(p);
            return null;
        }
        el = @ptrCast(@alignCast(c.gst_object_ref(pp)));
        unlock(p);
    }
    const list = if (p[0].direction == c.GST_PAD_SRC) &el[0].sinkpads else &el[0].srcpads;
    const it = c.gst_iterator_new_list(gst_pad_get_type(), &el[0].object.lock, &el[0].pads_cookie, list, @ptrCast(el), null);
    c.gst_object_unref(el);
    return it;
}

pub export fn gst_pad_iterate_internal_links(p: [*c]Pad) [*c]c.GstIterator {
    if (!check.that(isPad(p), "gst_pad_iterate_internal_links", "GST_IS_PAD (pad)")) return null;
    lock(p);
    var parent: [*c]Obj = null;
    if (!acquireParent(p, &parent)) {
        unlock(p);
        return null;
    }
    unlock(p);
    var r: [*c]c.GstIterator = null;
    if (p[0].iterintlinkfunc) |f| r = f(h(p), parent);
    releaseParent(parent);
    return r;
}

pub export fn gst_pad_forward(p: [*c]Pad, forward: c.GstPadForwardFunction, data: c.gpointer) c.gboolean {
    const it = gst_pad_iterate_internal_links(p);
    if (it == null) return 0;
    const pushed = c.g_hash_table_new(null, null);
    var item = std.mem.zeroes(c.GValue);
    var result: c.gboolean = 0;
    var resynced = false;
    var done = false;
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const ip = c.g_value_get_object(&item);
                if (ip != null and !(resynced and c.g_hash_table_contains(pushed, ip) != 0)) {
                    result = forward.?(@ptrCast(@alignCast(ip)), data);
                    done = result != 0;
                    _ = c.g_hash_table_add(pushed, ip);
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                resynced = true;
            },
            else => done = true,
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    c.g_hash_table_destroy(pushed);
    return result;
}

pub export fn gst_pad_get_offset(p: [*c]Pad) c.gint64 {
    if (!check.that(isPad(p), "gst_pad_get_offset", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    defer unlock(p);
    return p[0].offset;
}

fn notReceived(_: [*c]Pad, ev: *PadEvent, _: ?*anyopaque) bool {
    ev.received = 0;
    return true;
}

pub export fn gst_pad_set_offset(p: [*c]Pad, offset: c.gint64) void {
    if (!check.that(isPad(p), "gst_pad_set_offset", "GST_IS_PAD (pad)")) return;
    lock(p);
    defer unlock(p);
    if (p[0].offset == offset) return;
    p[0].offset = offset;
    eachEvent(p, notReceived, null);
    set(p, c.GST_PAD_FLAG_PENDING_EVENTS);
}

pub export fn gst_pad_set_element_private(p: [*c]Pad, data: c.gpointer) void {
    p[0].element_private = data;
}

pub export fn gst_pad_get_element_private(p: [*c]Pad) c.gpointer {
    return p[0].element_private;
}

pub export fn gst_pad_get_sticky_event(p: [*c]Pad, t: c.GstEventType, idx: c.guint) [*c]Event {
    if (!check.that(isPad(p), "gst_pad_get_sticky_event", "GST_IS_PAD (pad)")) return null;
    if (!check.that(t & c.GST_EVENT_TYPE_STICKY != 0, "gst_pad_get_sticky_event", "(event_type & GST_EVENT_TYPE_STICKY) != 0")) return null;
    lock(p);
    defer unlock(p);
    const ev = findByType(p, t, idx) orelse return null;
    if (ev.event != null) _ = c.gst_mini_object_ref(@ptrCast(ev.event));
    return ev.event;
}

const Dispatch = struct { func: c.GstPadStickyEventsForeachFunction, data: c.gpointer };

fn dispatchOne(p: [*c]Pad, ev: *PadEvent, data: ?*anyopaque) bool {
    const d: *Dispatch = @ptrCast(@alignCast(data));
    if (ev.event == null) return true;
    unlock(p);
    const r = d.func.?(h(p), &ev.event, d.data) != 0;
    lock(p);
    return r;
}

pub export fn gst_pad_sticky_events_foreach(p: [*c]Pad, func: c.GstPadStickyEventsForeachFunction, data: c.gpointer) void {
    if (!check.that(isPad(p), "gst_pad_sticky_events_foreach", "GST_IS_PAD (pad)")) return;
    if (!check.that(func != null, "gst_pad_sticky_events_foreach", "foreach_func != NULL")) return;
    var d = Dispatch{ .func = func, .data = data };
    lock(p);
    eachEvent(p, dispatchOne, &d);
    unlock(p);
}

fn streamStatus(p: [*c]Pad, kind: c.GstStreamStatusType, task: [*c]c.GstTask) void {
    const parent = c.gst_object_get_parent(@ptrCast(p));
    if (parent == null) return;
    defer c.gst_object_unref(parent);
    if (!isElement(parent)) return;
    if (kind == c.GST_STREAM_STATUS_TYPE_ENTER) {
        const name = c.g_strdup_printf("%s:%s", parentName(p), padName(p));
        _ = c.gst_object_set_name(@ptrCast(task), name);
        c.g_free(name);
    }
    const msg = c.gst_message_new_stream_status(@ptrCast(p), kind, @ptrCast(parent));
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_task_get_type());
    c.g_value_set_object(&v, task);
    c.gst_message_set_stream_status_object(msg, &v);
    c.g_value_unset(&v);
    post(@ptrCast(parent), msg);
}

fn enterThread(task: [*c]c.GstTask, _: ?*c.GThread, data: c.gpointer) callconv(.c) void {
    streamStatus(@ptrCast(@alignCast(data)), c.GST_STREAM_STATUS_TYPE_ENTER, task);
}

fn leaveThread(task: [*c]c.GstTask, _: ?*c.GThread, data: c.gpointer) callconv(.c) void {
    streamStatus(@ptrCast(@alignCast(data)), c.GST_STREAM_STATUS_TYPE_LEAVE, task);
}

pub export fn gst_pad_start_task(p: [*c]Pad, func: c.GstTaskFunction, data: c.gpointer, notify_in: c.GDestroyNotify) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_start_task", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(func != null, "gst_pad_start_task", "func != NULL")) return 0;
    var notify = notify_in;
    lock(p);
    var task = p[0].task;
    if (task == null) {
        task = c.gst_task_new(func, data, notify);
        notify = null;
        c.gst_task_set_lock(task, &p[0].stream_rec_lock);
        c.gst_task_set_enter_callback(task, enterThread, p, null);
        c.gst_task_set_leave_callback(task, leaveThread, p, null);
        p[0].task = task;
        _ = c.gst_object_ref(task);
        unlock(p);
        streamStatus(p, c.GST_STREAM_STATUS_TYPE_CREATE, task);
        c.gst_object_unref(task);
        lock(p);
        if (p[0].task != task) {
            unlock(p);
            return 1;
        }
    }
    const r = c.gst_task_set_state(task, c.GST_TASK_STARTED);
    unlock(p);
    if (notify) |n| n(data);
    return r;
}

fn endActivation(p: [*c]Pad) void {
    priv(p).in_activation = 0;
    c.g_cond_broadcast(&priv(p).activation_cond);
}

pub export fn gst_pad_pause_task(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_pause_task", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    const task = p[0].task;
    if (task == null) {
        unlock(p);
        return 0;
    }
    const r = c.gst_task_set_state(task, c.GST_TASK_PAUSED);
    endActivation(p);
    unlock(p);
    streamLock(p);
    streamUnlock(p);
    return r;
}

pub export fn gst_pad_get_task_state(p: [*c]Pad) c.GstTaskState {
    if (!check.that(isPad(p), "gst_pad_get_task_state", "GST_IS_PAD (pad)")) return c.GST_TASK_STOPPED;
    lock(p);
    defer unlock(p);
    if (p[0].task == null) return c.GST_TASK_STOPPED;
    return c.gst_task_get_state(p[0].task);
}

pub export fn gst_pad_stop_task(p: [*c]Pad) c.gboolean {
    if (!check.that(isPad(p), "gst_pad_stop_task", "GST_IS_PAD (pad)")) return 0;
    lock(p);
    const task = p[0].task;
    if (task == null) {
        unlock(p);
        streamLock(p);
        streamUnlock(p);
        return 1;
    }
    p[0].task = null;
    const r = c.gst_task_set_state(task, c.GST_TASK_STOPPED);
    endActivation(p);
    unlock(p);
    streamLock(p);
    streamUnlock(p);
    if (c.gst_task_join(task) == 0) {
        lock(p);
        if (p[0].task == null) p[0].task = task;
        unlock(p);
        return 0;
    }
    c.gst_object_unref(task);
    return r;
}

pub export fn gst_pad_probe_info_get_type(pi: [*c]c.GstPadProbeInfo) c.GstPadProbeType {
    return pi[0].type;
}

pub export fn gst_pad_probe_info_get_id(pi: [*c]c.GstPadProbeInfo) c.gulong {
    return pi[0].id;
}

pub export fn gst_pad_probe_info_get_offset(pi: [*c]c.GstPadProbeInfo) c.guint64 {
    return pi[0].offset;
}

pub export fn gst_pad_probe_info_get_size(pi: [*c]c.GstPadProbeInfo) c.gsize {
    return pi[0].size;
}

pub export fn gst_pad_probe_info_get_flow_return(pi: [*c]c.GstPadProbeInfo) c.GstFlowReturn {
    return pi[0].ABI.abi.flow_ret;
}

const EVENTS = c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_UPSTREAM;
const QUERIES = c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_QUERY_UPSTREAM;

pub export fn gst_pad_probe_info_get_event(pi: [*c]c.GstPadProbeInfo) [*c]Event {
    if (!check.that(pi[0].type & EVENTS != 0, "gst_pad_probe_info_get_event", "info->type & (GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | GST_PAD_PROBE_TYPE_EVENT_UPSTREAM)")) return null;
    return @ptrCast(@alignCast(pi[0].data));
}

pub export fn gst_pad_probe_info_get_query(pi: [*c]c.GstPadProbeInfo) [*c]Query {
    if (!check.that(pi[0].type & QUERIES != 0, "gst_pad_probe_info_get_query", "info->type & (GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM | GST_PAD_PROBE_TYPE_QUERY_UPSTREAM)")) return null;
    return @ptrCast(@alignCast(pi[0].data));
}

pub export fn gst_pad_probe_info_get_buffer(pi: [*c]c.GstPadProbeInfo) [*c]c.GstBuffer {
    if (!check.that(pi[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0, "gst_pad_probe_info_get_buffer", "info->type & GST_PAD_PROBE_TYPE_BUFFER")) return null;
    return @ptrCast(@alignCast(pi[0].data));
}

pub export fn gst_pad_probe_info_get_buffer_list(pi: [*c]c.GstPadProbeInfo) ?*c.GstBufferList {
    if (!check.that(pi[0].type & c.GST_PAD_PROBE_TYPE_BUFFER_LIST != 0, "gst_pad_probe_info_get_buffer_list", "info->type & GST_PAD_PROBE_TYPE_BUFFER_LIST")) return null;
    return @ptrCast(@alignCast(pi[0].data));
}

fn replaceData(pi: [*c]c.GstPadProbeInfo, v: c.gpointer) void {
    if (pi[0].data != null) c.gst_mini_object_unref(@ptrCast(@alignCast(pi[0].data)));
    pi[0].data = v;
}

pub export fn gst_pad_probe_info_set_event(pi: [*c]c.GstPadProbeInfo, e: [*c]Event) void {
    if (!check.that(pi[0].type & EVENTS != 0, "gst_pad_probe_info_set_event", "info->type & (GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | GST_PAD_PROBE_TYPE_EVENT_UPSTREAM)")) return;
    replaceData(pi, e);
}

pub export fn gst_pad_probe_info_set_buffer(pi: [*c]c.GstPadProbeInfo, b: [*c]c.GstBuffer) void {
    if (!check.that(pi[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0, "gst_pad_probe_info_set_buffer", "info->type & GST_PAD_PROBE_TYPE_BUFFER")) return;
    replaceData(pi, b);
}

pub export fn gst_pad_probe_info_set_buffer_list(pi: [*c]c.GstPadProbeInfo, l: ?*c.GstBufferList) void {
    if (!check.that(pi[0].type & c.GST_PAD_PROBE_TYPE_BUFFER_LIST != 0, "gst_pad_probe_info_set_buffer_list", "info->type & GST_PAD_PROBE_TYPE_BUFFER_LIST")) return;
    replaceData(pi, l);
}

pub export fn gst_pad_probe_info_set_flow_return(pi: [*c]c.GstPadProbeInfo, r: c.GstFlowReturn) void {
    pi[0].ABI.abi.flow_ret = r;
}

pub export fn gst_pad_get_last_flow_return(p: [*c]Pad) c.GstFlowReturn {
    lock(p);
    defer unlock(p);
    return lastFlow(p).*;
}

pub export fn gst_pad_use_fixed_caps(p: [*c]Pad) void {
    set(p, c.GST_PAD_FLAG_FIXED_CAPS);
}

pub export fn gst_pad_get_parent_element(p: [*c]Pad) [*c]c.GstElement {
    if (!check.that(isPad(p), "gst_pad_get_parent_element", "GST_IS_PAD (pad)")) return null;
    const o = c.gst_object_get_parent(@ptrCast(p));
    if (o != null and !isElement(o)) {
        c.gst_object_unref(o);
        return null;
    }
    return @ptrCast(@alignCast(o));
}

pub export fn gst_pad_check_link(src: [*c]Pad, sink: [*c]Pad) c.gboolean {
    if (!check.that(isPad(src), "gst_pad_check_link", "GST_IS_PAD (srcpad)")) return 0;
    if (!check.that(isPad(sink), "gst_pad_check_link", "GST_IS_PAD (sinkpad)")) return 0;
    if (src[0].peer != null or sink[0].peer != null) return 0;
    if (!isSrc(src) or !isSink(sink)) return 0;
    return @intFromBool(parentOf(src) != null and parentOf(sink) != null);
}

pub export fn gst_pad_get_stream_id(p: [*c]Pad) [*c]u8 {
    if (!check.that(isPad(p), "gst_pad_get_stream_id", "GST_IS_PAD (pad)")) return null;
    const e = gst_pad_get_sticky_event(p, c.GST_EVENT_STREAM_START, 0);
    if (e == null) return null;
    var id: [*c]const u8 = null;
    c.gst_event_parse_stream_start(e, &id);
    const r = c.g_strdup(id);
    c.gst_mini_object_unref(@ptrCast(e));
    return r;
}

pub export fn gst_pad_get_stream(p: [*c]Pad) [*c]c.GstStream {
    if (!check.that(isPad(p), "gst_pad_get_stream", "GST_IS_PAD (pad)")) return null;
    const e = gst_pad_get_sticky_event(p, c.GST_EVENT_STREAM_START, 0);
    if (e == null) return null;
    var s: [*c]c.GstStream = null;
    c.gst_event_parse_stream(e, &s);
    c.gst_mini_object_unref(@ptrCast(e));
    return s;
}
