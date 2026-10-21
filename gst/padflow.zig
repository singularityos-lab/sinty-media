const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");
const pad = @import("pad.zig");
const info = @import("info.zig");

comptime {
    @import("abi.zig").check(@This());
}

const Pad = pad.Pad;
const Raw = pad.Raw;
const h = pad.h;
const of = pad.of;
const Obj = c.GstObject;
const Event = c.GstEvent;
const Query = c.GstQuery;
const Caps = c.GstCaps;
const Flow = c.GstFlowReturn;
const SUCCESS_1 = pad.SUCCESS_1;
const lock = pad.lock;
const unlock = pad.unlock;
const has = pad.has;
const set = pad.set;
const clear = pad.clear;
const isSrc = pad.isSrc;
const isSink = pad.isSink;
const PadEvent = pad.PadEvent;
const STACK_PROBES = 16;

const Marshal = struct {
    pad: [*c]Pad,
    info: *c.GstPadProbeInfo,
    dropped: bool = false,
    pass: bool = false,
    handled: bool = false,
    marshalled: bool = false,
    called: std.ArrayListUnmanaged(c.gulong) = .empty,
    retry: bool = false,
};

fn eventFlags(e: anytype) c.GstEventTypeFlags {
    return @as([*c]Event, @ptrCast(@alignCast(e)))[0].type;
}

fn isSerialized(e: anytype) bool {
    return eventFlags(e) & c.GST_EVENT_TYPE_SERIALIZED != 0;
}

fn isSticky(e: anytype) bool {
    return eventFlags(e) & c.GST_EVENT_TYPE_STICKY != 0;
}

fn queryFlags(q: anytype) c.guint {
    return @as([*c]Query, @ptrCast(@alignCast(q)))[0].type;
}

fn alreadyCalled(hook: [*c]c.GHook, m: *Marshal) bool {
    if (m.retry) for (m.called.items) |id| if (id == hook[0].hook_id) return true;
    m.called.append(std.heap.c_allocator, hook[0].hook_id) catch @panic("out of memory");
    return false;
}

fn marshalOne(hook: [*c]c.GHook, data: c.gpointer) callconv(.c) void {
    const m: *Marshal = @ptrCast(@alignCast(data));
    const p = m.pad;
    const pi = m.info;
    const fl = hook[0].flags >> 4;
    const kind = pi.type;
    const original = pi.data;
    if (fl & c.GST_PAD_PROBE_TYPE_SCHEDULING & kind == 0) return;
    if (m.handled or m.dropped) return;
    if (kind & c.GST_PAD_PROBE_TYPE_PUSH != 0) {
        if (kind & c.GST_PAD_PROBE_TYPE_IDLE == 0 and fl & pad.ALL_BOTH_AND_FLUSH & kind == 0) return;
    } else if (kind & c.GST_PAD_PROBE_TYPE_PULL != 0) {
        if (kind & c.GST_PAD_PROBE_TYPE_BLOCKING == 0 and fl & pad.ALL_BOTH_AND_FLUSH & kind == 0) return;
    }
    if (kind & c.GST_PAD_PROBE_TYPE_BLOCKING != 0 and fl & c.GST_PAD_PROBE_TYPE_BLOCKING & kind == 0) return;
    if (kind & c.GST_PAD_PROBE_TYPE_BLOCKING == 0 and fl & c.GST_PAD_PROBE_TYPE_BLOCKING != 0) return;
    if (kind & c.GST_PAD_PROBE_TYPE_EVENT_FLUSH != 0 and fl & c.GST_PAD_PROBE_TYPE_EVENT_FLUSH & kind == 0) return;
    if (alreadyCalled(hook, m)) {
        m.marshalled = true;
        return;
    }
    const cb: c.GstPadProbeCallback = @ptrCast(hook[0].func);
    const callback = cb orelse {
        m.marshalled = true;
        return;
    };
    pi.id = hook[0].hook_id;
    const idle = fl & c.GST_PAD_PROBE_TYPE_IDLE != 0;
    if (idle) pad.priv(p).idle_running += 1;
    unlock(p);
    const ret = callback(h(p), pi, hook[0].data);
    lock(p);
    if (ret != c.GST_PAD_PROBE_REMOVE) m.marshalled = true;
    if (idle) pad.priv(p).idle_running -= 1;
    if (ret != c.GST_PAD_PROBE_HANDLED and original != null and pi.data == null) {
        pi.type = c.GST_PAD_PROBE_TYPE_INVALID;
        m.dropped = true;
    }
    switch (ret) {
        c.GST_PAD_PROBE_REMOVE => pad.cleanupHook(p, hook),
        c.GST_PAD_PROBE_DROP => {
            pi.type = c.GST_PAD_PROBE_TYPE_INVALID;
            m.dropped = true;
        },
        c.GST_PAD_PROBE_HANDLED => m.handled = true,
        c.GST_PAD_PROBE_PASS => m.pass = true,
        else => {},
    }
}

fn idleWait(p: [*c]Pad) Flow {
    while (pad.priv(p).idle_running > 0) {
        set(p, c.GST_PAD_FLAG_BLOCKING);
        pad.blockWait(p);
        clear(p, c.GST_PAD_FLAG_BLOCKING);
        if (has(p, c.GST_PAD_FLAG_FLUSHING)) return c.GST_FLOW_FLUSHING;
    }
    return c.GST_FLOW_OK;
}

fn serializedProbe(pi: *c.GstPadProbeInfo) bool {
    if (pi.type & (c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH) != 0 and isSerialized(pi.data)) return true;
    if (pi.type & c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM != 0 and queryFlags(pi.data) & c.GST_QUERY_TYPE_SERIALIZED != 0) return true;
    return pi.type & (c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_BUFFER_LIST) != 0;
}

fn runProbes(p: [*c]Pad, pi: *c.GstPadProbeInfo, default: Flow) Flow {
    var m = Marshal{ .pad = p, .info = pi };
    defer m.called.deinit(std.heap.c_allocator);
    const block = pi.type & c.GST_PAD_PROBE_TYPE_BLOCK == c.GST_PAD_PROBE_TYPE_BLOCK;
    if (block and serializedProbe(pi) and idleWait(p) == c.GST_FLOW_FLUSHING) return c.GST_FLOW_FLUSHING;
    again: while (true) {
        const cookie = pad.priv(p).probe_cookie;
        m.marshalled = false;
        c.g_hook_list_marshal(@ptrCast(&p[0].probes), 1, marshalOne, &m);
        if (cookie != pad.priv(p).probe_cookie) {
            m.retry = true;
            continue :again;
        }
        if (m.dropped) return c.GST_FLOW_CUSTOM_SUCCESS;
        if (m.handled) return SUCCESS_1;
        if ((!m.marshalled and block) or m.pass) return c.GST_FLOW_OK;
        if (block) {
            while (has(p, c.GST_PAD_FLAG_BLOCKED)) {
                if (has(p, c.GST_PAD_FLAG_FLUSHING)) return c.GST_FLOW_FLUSHING;
                set(p, c.GST_PAD_FLAG_BLOCKING);
                pad.blockWait(p);
                clear(p, c.GST_PAD_FLAG_BLOCKING);
                if (cookie != pad.priv(p).probe_cookie) {
                    m.retry = true;
                    continue :again;
                }
                if (has(p, c.GST_PAD_FLAG_FLUSHING)) return c.GST_FLOW_FLUSHING;
            }
        }
        return default;
    }
}

const Probe = struct { ret: Flow, stop: bool, handled: bool };

fn probe(p: [*c]Pad, mask: c.GstPadProbeType, data: *c.gpointer, offset: u64, size: c.guint, handleable: bool) Probe {
    if (p[0].num_probes == 0) return .{ .ret = c.GST_FLOW_OK, .stop = false, .handled = false };
    var pi = std.mem.zeroes(c.GstPadProbeInfo);
    pi.type = mask;
    pi.data = data.*;
    pi.offset = offset;
    pi.size = size;
    pi.ABI.abi.flow_ret = c.GST_FLOW_OK;
    var ret = runProbes(p, &pi, c.GST_FLOW_OK);
    data.* = pi.data;
    if (ret == c.GST_FLOW_OK) return .{ .ret = ret, .stop = false, .handled = false };
    if (handleable and ret == SUCCESS_1) {
        ret = pi.ABI.abi.flow_ret;
        return .{ .ret = ret, .stop = true, .handled = true };
    }
    return .{ .ret = ret, .stop = true, .handled = false };
}

fn probeIdle(p: [*c]Pad, mask: c.GstPadProbeType, default: Flow) ?Flow {
    if (p[0].num_probes == 0) return null;
    var pi = std.mem.zeroes(c.GstPadProbeInfo);
    pi.type = mask;
    pi.ABI.abi.flow_ret = default;
    const r = runProbes(p, &pi, default);
    if (r != default and r != c.GST_FLOW_OK) return r;
    return null;
}

pub fn chainListDefault(raw: Raw, _: [*c]Obj, list: ?*c.GstBufferList) callconv(.c) Flow {
    const p = of(raw);
    var ret: Flow = c.GST_FLOW_OK;
    if (c.gst_buffer_list_is_writable(list) != 0) {
        var d = ListData{ .pad = p, .ret = c.GST_FLOW_OK };
        _ = c.gst_buffer_list_foreach(list, chainEach, &d);
        ret = d.ret;
    } else {
        const n = c.gst_buffer_list_length(list);
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const b = c.gst_buffer_list_get(list, i);
            ret = chainData(p, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_PUSH, c.gst_buffer_ref(b));
            if (ret != c.GST_FLOW_OK) break;
        }
    }
    c.gst_buffer_list_unref(list);
    return ret;
}

const ListData = struct { pad: [*c]Pad, ret: Flow };

fn chainEach(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *ListData = @ptrCast(@alignCast(data));
    d.ret = chainData(d.pad, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_PUSH, b.*);
    b.* = null;
    return @intFromBool(d.ret == c.GST_FLOW_OK);
}

const EventData = struct { event: [*c]Event, result: c.gboolean, dispatched: bool };

fn eventForward(raw: Raw, data: c.gpointer) callconv(.c) c.gboolean {
    const p = of(raw);
    const d: *EventData = @ptrCast(@alignCast(data));
    d.result |= gst_pad_push_event(p, @ptrCast(c.gst_mini_object_ref(@ptrCast(d.event))));
    d.dispatched = true;
    return 0;
}

pub export fn gst_pad_event_default(raw: Raw, _: [*c]Obj, e: [*c]Event) c.gboolean {
    const p = of(raw);
    if (!check.that(pad.isPad(p), "gst_pad_event_default", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(e != null, "gst_pad_event_default", "event != NULL")) return 0;
    var result: c.gboolean = 1;
    var forward = true;
    if (e[0].type == c.GST_EVENT_CAPS) forward = has(p, c.GST_PAD_FLAG_PROXY_CAPS);
    if (forward) {
        var d = EventData{ .event = e, .result = 0, .dispatched = false };
        _ = pad.gst_pad_forward(p, eventForward, &d);
        result = if (d.dispatched) d.result else 1;
    }
    c.gst_mini_object_unref(@ptrCast(e));
    return result;
}

fn acceptCapsDefault(p: [*c]Pad, q: [*c]Query) bool {
    var allowed: [*c]Caps = null;
    if (has(p, c.GST_PAD_FLAG_PROXY_CAPS)) {
        if (gst_pad_proxy_query_accept_caps(p, q) == 0) return true;
        allowed = pad.gst_pad_get_pad_template_caps(p);
    }
    var caps: [*c]Caps = null;
    c.gst_query_parse_accept_caps(q, &caps);
    if (allowed == null) {
        allowed = if (has(p, c.GST_PAD_FLAG_ACCEPT_TEMPLATE)) pad.gst_pad_get_pad_template_caps(p) else gst_pad_query_caps(p, caps);
    }
    var result: c.gboolean = 0;
    if (allowed != null) {
        result = if (has(p, c.GST_PAD_FLAG_ACCEPT_INTERSECT)) c.gst_caps_can_intersect(caps, allowed) else c.gst_caps_is_subset(caps, allowed);
        c.gst_caps_unref(allowed);
    }
    c.gst_query_set_accept_caps_result(q, result);
    return true;
}

fn capsDefault(p: [*c]Pad, q: [*c]Query) bool {
    if (has(p, c.GST_PAD_FLAG_PROXY_CAPS) and gst_pad_proxy_query_caps(p, q) != 0) return true;
    var filter: [*c]Caps = null;
    c.gst_query_parse_caps(q, &filter);
    const fixed = has(p, c.GST_PAD_FLAG_FIXED_CAPS);
    lock(p);
    var result: [*c]Caps = null;
    if (fixed) result = pad.currentCaps(p);
    if (result == null and p[0].padtemplate != null) result = p[0].padtemplate[0].caps;
    if (result == null and !fixed) result = pad.currentCaps(p);
    if (result == null) result = c._gst_caps_any;
    unlock(p);
    result = if (filter != null) c.gst_caps_intersect_full(filter, result, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_ref(result);
    c.gst_query_set_caps_result(q, result);
    c.gst_caps_unref(result);
    return true;
}

const Latency = struct { live: bool, min: u64, max: u64 };

fn latencyFold(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const p: [*c]Pad = @ptrCast(@alignCast(c.g_value_get_object(item)));
    const d: *Latency = @ptrCast(@alignCast(data));
    const q = c.gst_query_new_latency();
    const peer = pad.gst_pad_get_peer(p);
    const ok = peer != null and gst_pad_peer_query(p, q) != 0;
    if (ok) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        c.gst_query_parse_latency(q, &live, &min, &max);
        if (live != 0) {
            if (min > d.min) d.min = min;
            if (d.max == std.math.maxInt(u64)) d.max = max else if (max < d.max) d.max = max;
            d.live = true;
        }
    } else if (peer != null) c.g_value_set_boolean(ret, 0);
    c.gst_query_unref(q);
    if (peer != null) c.gst_object_unref(peer);
    return 1;
}

fn latencyDefault(p: [*c]Pad, q: [*c]Query) bool {
    const it = pad.gst_pad_iterate_internal_links(p);
    if (it == null) return false;
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    var d: Latency = undefined;
    while (true) {
        d = .{ .live = false, .min = 0, .max = std.math.maxInt(u64) };
        c.g_value_set_boolean(&ret, 1);
        const r = c.gst_iterator_fold(it, latencyFold, &ret, &d);
        if (r == c.GST_ITERATOR_RESYNC) {
            c.gst_iterator_resync(it);
            continue;
        }
        if (r == c.GST_ITERATOR_ERROR) c.g_value_set_boolean(&ret, 0);
        break;
    }
    c.gst_iterator_free(it);
    const ok = c.g_value_get_boolean(&ret) != 0;
    if (ok) {
        if (d.min > d.max) info.gst_debug_log(info.GST_CAT_PADS, c.GST_LEVEL_ERROR, "../gst/gstpad.c", "gst_pad_query_latency_default", 0, @ptrCast(p), "minimum latency bigger than maximum latency");
        c.gst_query_set_latency(q, @intFromBool(d.live), d.min, d.max);
    }
    return ok;
}

const QueryData = struct { query: [*c]Query, result: c.gboolean, dispatched: bool };

fn queryForward(raw: Raw, data: c.gpointer) callconv(.c) c.gboolean {
    const p = of(raw);
    const d: *QueryData = @ptrCast(@alignCast(data));
    d.result |= gst_pad_peer_query(p, d.query);
    d.dispatched = true;
    return d.result;
}

pub export fn gst_pad_query_default(raw: Raw, _: [*c]Obj, q: [*c]Query) c.gboolean {
    const p = of(raw);
    var forward = true;
    var ret = false;
    switch (q[0].type) {
        c.GST_QUERY_SCHEDULING => forward = has(p, c.GST_PAD_FLAG_PROXY_SCHEDULING),
        c.GST_QUERY_ALLOCATION => forward = has(p, c.GST_PAD_FLAG_PROXY_ALLOCATION),
        c.GST_QUERY_ACCEPT_CAPS => {
            ret = acceptCapsDefault(p, q);
            forward = false;
        },
        c.GST_QUERY_CAPS => {
            ret = capsDefault(p, q);
            forward = false;
        },
        c.GST_QUERY_LATENCY => {
            ret = latencyDefault(p, q);
            forward = false;
        },
        else => {},
    }
    if (forward) {
        var d = QueryData{ .query = q, .result = 0, .dispatched = false };
        _ = pad.gst_pad_forward(p, queryForward, &d);
        ret = if (d.dispatched) d.result != 0 else q[0].type == c.GST_QUERY_DRAIN;
    }
    return @intFromBool(ret);
}

const Sticky = struct { ret: Flow, was_eos: bool, event: [*c]Event };

fn pushSticky(p: [*c]Pad, ev: *PadEvent, data: ?*anyopaque) bool {
    const d: *Sticky = @ptrCast(@alignCast(data));
    const e = ev.event;
    if (ev.received != 0) return true;
    const seg_order = pad.order(c.GST_EVENT_SEGMENT);
    const d_order: c.guint = if (d.event != null) pad.order(d.event[0].type) else 0;
    if (d.event != null and isSticky(d.event) and d_order <= seg_order and d_order < ev.order) {
        d.ret = SUCCESS_1;
    } else {
        unlock(p);
        lock(p);
        d.ret = pushEventUnchecked(p, @ptrCast(c.gst_mini_object_ref(@ptrCast(e))), c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM);
        unlock(p);
        lock(p);
        if (d.ret == SUCCESS_1) d.ret = c.GST_FLOW_OK;
    }
    switch (d.ret) {
        c.GST_FLOW_OK => ev.received = 1,
        c.GST_FLOW_CUSTOM_SUCCESS, SUCCESS_1 => {
            set(p, c.GST_PAD_FLAG_PENDING_EVENTS);
            d.ret = c.GST_FLOW_OK;
        },
        c.GST_FLOW_NOT_LINKED => if (e[0].type != c.GST_EVENT_EOS) {
            d.ret = c.GST_FLOW_OK;
            ev.received = 1;
        },
        else => set(p, c.GST_PAD_FLAG_PENDING_EVENTS),
    }
    if (d.ret != c.GST_FLOW_OK and e[0].type == c.GST_EVENT_EOS) d.was_eos = true;
    return d.ret == c.GST_FLOW_OK;
}

fn checkSticky(p: [*c]Pad, e: [*c]Event) Flow {
    var d = Sticky{ .ret = c.GST_FLOW_OK, .was_eos = false, .event = e };
    if (!has(p, c.GST_PAD_FLAG_PENDING_EVENTS)) return d.ret;
    clear(p, c.GST_PAD_FLAG_PENDING_EVENTS);
    pad.eachEvent(p, pushSticky, &d);
    if (d.ret != c.GST_FLOW_OK and !d.was_eos) {
        if (pad.findByType(p, c.GST_EVENT_EOS, 0)) |ev| if (ev.received == 0) {
            const eos: [*c]Event = @ptrCast(c.gst_mini_object_ref(@ptrCast(ev.event)));
            unlock(p);
            lock(p);
            d.ret = pushEventUnchecked(p, eos, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM);
            unlock(p);
            lock(p);
            if (d.ret == c.GST_FLOW_CUSTOM_SUCCESS) d.ret = c.GST_FLOW_OK;
        };
    }
    return d.ret;
}

fn queryProbeResult(r: Flow) c.gboolean {
    return @intFromBool(r == SUCCESS_1);
}

pub export fn gst_pad_query(p: [*c]Pad, q: [*c]Query) c.gboolean {
    if (!check.that(pad.isPad(p), "gst_pad_query", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isQuery(q), "gst_pad_query", "GST_IS_QUERY (query)")) return 0;
    var kind: c.GstPadProbeType = undefined;
    if (isSrc(p)) {
        if (queryFlags(q) & c.GST_QUERY_TYPE_UPSTREAM == 0) return wrongQuery(p, q);
        kind = c.GST_PAD_PROBE_TYPE_QUERY_UPSTREAM;
    } else if (isSink(p)) {
        if (queryFlags(q) & c.GST_QUERY_TYPE_DOWNSTREAM == 0) return wrongQuery(p, q);
        kind = c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM;
    } else return badDirection(p);
    const serialized = queryFlags(q) & c.GST_QUERY_TYPE_SERIALIZED != 0;
    if (serialized) pad.streamLock(p);
    defer if (serialized) pad.streamUnlock(p);
    lock(p);
    var data: c.gpointer = q;
    var r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_BLOCK, &data, NONE64, NONE32, false);
    if (!r.stop) r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH, &data, NONE64, NONE32, false);
    if (r.stop) {
        unlock(p);
        return queryProbeResult(r.ret);
    }
    var parent: [*c]Obj = null;
    if (!pad.acquireParent(p, &parent)) {
        unlock(p);
        return 0;
    }
    unlock(p);
    const func = p[0].queryfunc orelse {
        pad.releaseParent(parent);
        return 0;
    };
    const res = func(h(p), parent, q);
    pad.releaseParent(parent);
    if (res != 1) return 0;
    lock(p);
    r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PULL, &data, NONE64, NONE32, false);
    unlock(p);
    if (r.stop) return queryProbeResult(r.ret);
    return res;
}

const NONE64: u64 = std.math.maxInt(u64);
const NONE32: c.guint = std.math.maxInt(c.guint);

fn isQuery(q: [*c]Query) bool {
    return q != null and q[0].mini_object.type == c.gst_query_get_type();
}

fn wrongQuery(p: [*c]Pad, q: [*c]Query) c.gboolean {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "pad %s:%s query %s in wrong direction", pad.parentName(p), pad.padName(p), c.gst_query_type_get_name(q[0].type));
    return 0;
}

fn badDirection(p: [*c]Pad) c.gboolean {
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "pad %s:%s has invalid direction", pad.parentName(p), pad.padName(p));
    return 0;
}

pub export fn gst_pad_peer_query(p: [*c]Pad, q: [*c]Query) c.gboolean {
    if (!check.that(pad.isPad(p), "gst_pad_peer_query", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isQuery(q), "gst_pad_peer_query", "GST_IS_QUERY (query)")) return 0;
    var kind: c.GstPadProbeType = undefined;
    if (isSrc(p)) {
        if (queryFlags(q) & c.GST_QUERY_TYPE_DOWNSTREAM == 0) return wrongQuery(p, q);
        kind = c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM;
    } else if (isSink(p)) {
        if (queryFlags(q) & c.GST_QUERY_TYPE_UPSTREAM == 0) return wrongQuery(p, q);
        kind = c.GST_PAD_PROBE_TYPE_QUERY_UPSTREAM;
    } else return badDirection(p);
    const serialized = queryFlags(q) & c.GST_QUERY_TYPE_SERIALIZED != 0;
    lock(p);
    if (isSrc(p) and serialized and checkSticky(p, null) != c.GST_FLOW_OK) {
        unlock(p);
        return 0;
    }
    var data: c.gpointer = q;
    var r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_BLOCK, &data, NONE64, NONE32, false);
    if (!r.stop) r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH, &data, NONE64, NONE32, false);
    if (r.stop) {
        unlock(p);
        return queryProbeResult(r.ret);
    }
    const peer = p[0].peer;
    if (peer == null) {
        unlock(p);
        return 0;
    }
    _ = c.gst_object_ref(peer);
    unlock(p);
    const res = gst_pad_query(peer, q);
    c.gst_object_unref(peer);
    if (res != 1) return 0;
    lock(p);
    r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PULL, &data, NONE64, NONE32, false);
    unlock(p);
    if (r.stop) return queryProbeResult(r.ret);
    return res;
}

fn extraChecks(p: [*c]Pad, comptime func: [:0]const u8, comptime start_line: [:0]const u8, comptime seg_line: [:0]const u8) void {
    const d = pad.priv(p);
    if (d.last_cookie == d.events_cookie) return;
    if (pad.findByType(p, c.GST_EVENT_STREAM_START, 0) == null)
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "../gst/gstpad.c:" ++ start_line ++ ":%s:<%s:%s> Got data flow before stream-start event", func.ptr, pad.parentName(p), pad.padName(p));
    if (pad.findByType(p, c.GST_EVENT_SEGMENT, 0) == null)
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "../gst/gstpad.c:" ++ seg_line ++ ":%s:<%s:%s> Got data flow before segment event", func.ptr, pad.parentName(p), pad.padName(p));
    d.last_cookie = d.events_cookie;
}

fn dropData(data: c.gpointer) void {
    if (data != null) c.gst_mini_object_unref(@ptrCast(@alignCast(data)));
}

fn foldStop(r: Flow) Flow {
    return if (r == c.GST_FLOW_CUSTOM_SUCCESS or r == SUCCESS_1) c.GST_FLOW_OK else r;
}

fn chainData(p: [*c]Pad, kind: c.GstPadProbeType, data_in: c.gpointer) Flow {
    var data = data_in;
    pad.streamLock(p);
    defer pad.streamUnlock(p);
    lock(p);
    if (has(p, c.GST_PAD_FLAG_FLUSHING) or has(p, c.GST_PAD_FLAG_EOS) or p[0].mode != c.GST_PAD_MODE_PUSH) {
        const r: Flow = if (has(p, c.GST_PAD_FLAG_FLUSHING)) c.GST_FLOW_FLUSHING else if (has(p, c.GST_PAD_FLAG_EOS)) c.GST_FLOW_EOS else blk: {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "chain on pad %s:%s but it was not in push mode", pad.parentName(p), pad.padName(p));
            break :blk c.GST_FLOW_ERROR;
        };
        pad.lastFlow(p).* = r;
        unlock(p);
        dropData(data);
        return r;
    }
    extraChecks(p, "gst_pad_chain_data_unchecked", "4524", "4529");
    var r = probe(p, kind | c.GST_PAD_PROBE_TYPE_BLOCK, &data, NONE64, NONE32, true);
    if (!r.stop) r = probe(p, kind, &data, NONE64, NONE32, true);
    if (r.stop) {
        if (!r.handled) dropData(data);
        const ret = foldStop(r.ret);
        pad.lastFlow(p).* = ret;
        unlock(p);
        return ret;
    }
    var parent: [*c]Obj = null;
    if (!pad.acquireParent(p, &parent)) {
        pad.lastFlow(p).* = c.GST_FLOW_FLUSHING;
        dropData(data);
        unlock(p);
        return c.GST_FLOW_FLUSHING;
    }
    unlock(p);
    var ret: Flow = undefined;
    if (kind & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        const f = p[0].chainfunc orelse return noChain(p, parent, data);
        ret = f(h(p), parent, @ptrCast(@alignCast(data)));
    } else {
        const f = p[0].chainlistfunc orelse return noChain(p, parent, data);
        ret = f(h(p), parent, @ptrCast(@alignCast(data)));
    }
    pad.lastFlow(p).* = ret;
    pad.releaseParent(parent);
    return ret;
}

fn noChain(p: [*c]Pad, parent: [*c]Obj, data: c.gpointer) Flow {
    pad.lastFlow(p).* = c.GST_FLOW_NOT_SUPPORTED;
    pad.releaseParent(parent);
    dropData(data);
    c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "chain on pad %s:%s but it has no chainfunction", pad.parentName(p), pad.padName(p));
    return c.GST_FLOW_NOT_SUPPORTED;
}

fn isBuffer(b: anytype) bool {
    return b != null and @as([*c]c.GstMiniObject, @ptrCast(@alignCast(b)))[0].type == c._gst_buffer_type;
}

fn isList(b: anytype) bool {
    return b != null and @as([*c]c.GstMiniObject, @ptrCast(@alignCast(b)))[0].type == c._gst_buffer_list_type;
}

pub export fn gst_pad_chain(p: [*c]Pad, b: [*c]c.GstBuffer) Flow {
    if (!check.that(pad.isPad(p), "gst_pad_chain", "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSink(p), "gst_pad_chain", "GST_PAD_IS_SINK (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isBuffer(b), "gst_pad_chain", "GST_IS_BUFFER (buffer)")) return c.GST_FLOW_ERROR;
    return chainData(p, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_PUSH, b);
}

pub export fn gst_pad_chain_list(p: [*c]Pad, l: ?*c.GstBufferList) Flow {
    if (!check.that(pad.isPad(p), "gst_pad_chain_list", "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSink(p), "gst_pad_chain_list", "GST_PAD_IS_SINK (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isList(l), "gst_pad_chain_list", "GST_IS_BUFFER_LIST (list)")) return c.GST_FLOW_ERROR;
    return chainData(p, c.GST_PAD_PROBE_TYPE_BUFFER_LIST | c.GST_PAD_PROBE_TYPE_PUSH, l);
}

fn pushData(p: [*c]Pad, kind: c.GstPadProbeType, data_in: c.gpointer) Flow {
    var data = data_in;
    lock(p);
    if (has(p, c.GST_PAD_FLAG_FLUSHING) or has(p, c.GST_PAD_FLAG_EOS) or p[0].mode != c.GST_PAD_MODE_PUSH) {
        const r: Flow = if (has(p, c.GST_PAD_FLAG_FLUSHING)) c.GST_FLOW_FLUSHING else if (has(p, c.GST_PAD_FLAG_EOS)) c.GST_FLOW_EOS else blk: {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "pushing on pad %s:%s but it was not activated in push mode", pad.parentName(p), pad.padName(p));
            break :blk c.GST_FLOW_ERROR;
        };
        pad.lastFlow(p).* = r;
        unlock(p);
        dropData(data);
        return r;
    }
    extraChecks(p, "gst_pad_push_data", "4814", "4819");
    const masks = [_]c.GstPadProbeType{ kind | c.GST_PAD_PROBE_TYPE_BLOCK, kind };
    for (masks) |m| {
        const s = checkSticky(p, null);
        if (s != c.GST_FLOW_OK) return eventsError(p, s, data);
        const r = probe(p, m, &data, NONE64, NONE32, true);
        if (r.stop) {
            unlock(p);
            if (data != null and !r.handled) dropData(data);
            const ret = foldStop(r.ret);
            pad.lastFlow(p).* = ret;
            return ret;
        }
    }
    const s = checkSticky(p, null);
    if (s != c.GST_FLOW_OK) return eventsError(p, s, data);
    const peer = p[0].peer;
    if (peer == null) {
        pad.lastFlow(p).* = c.GST_FLOW_NOT_LINKED;
        unlock(p);
        dropData(data);
        return c.GST_FLOW_NOT_LINKED;
    }
    _ = c.gst_object_ref(peer);
    pad.priv(p).using += 1;
    unlock(p);
    var ret = chainData(peer, kind, data);
    c.gst_object_unref(peer);
    lock(p);
    pad.lastFlow(p).* = ret;
    pad.priv(p).using -= 1;
    if (pad.priv(p).using == 0) {
        if (probeIdle(p, c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_IDLE, ret)) |stopped| {
            unlock(p);
            ret = foldStop(stopped);
            pad.lastFlow(p).* = ret;
            return ret;
        }
    }
    unlock(p);
    return ret;
}

fn eventsError(p: [*c]Pad, r: Flow, data: c.gpointer) Flow {
    pad.lastFlow(p).* = r;
    unlock(p);
    dropData(data);
    return r;
}

pub export fn gst_pad_push(p: [*c]Pad, b: [*c]c.GstBuffer) Flow {
    if (!check.that(pad.isPad(p), "gst_pad_push", "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSrc(p), "gst_pad_push", "GST_PAD_IS_SRC (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isBuffer(b), "gst_pad_push", "GST_IS_BUFFER (buffer)")) return c.GST_FLOW_ERROR;
    return pushData(p, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_PUSH, b);
}

pub export fn gst_pad_push_list(p: [*c]Pad, l: ?*c.GstBufferList) Flow {
    if (!check.that(pad.isPad(p), "gst_pad_push_list", "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSrc(p), "gst_pad_push_list", "GST_PAD_IS_SRC (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isList(l), "gst_pad_push_list", "GST_IS_BUFFER_LIST (list)")) return c.GST_FLOW_ERROR;
    return pushData(p, c.GST_PAD_PROBE_TYPE_BUFFER_LIST | c.GST_PAD_PROBE_TYPE_PUSH, l);
}

fn pullProbe(p: [*c]Pad, mask: c.GstPadProbeType, buf: *[*c]c.GstBuffer, offset: u64, size: c.guint) Probe {
    var data: c.gpointer = buf.*;
    const r = probe(p, mask, &data, offset, size, false);
    buf.* = @ptrCast(@alignCast(data));
    return r;
}

fn logFail(p: [*c]Pad, comptime what: [:0]const u8, r: Flow) void {
    const level: c.GstDebugLevel = if (r >= c.GST_FLOW_EOS) c.GST_LEVEL_INFO else c.GST_LEVEL_WARNING;
    info.gst_debug_log(info.GST_CAT_SCHEDULING, level, "../gst/gstpad.c", what, 0, @ptrCast(p), what ++ " failed, flow: %s", pad.gst_flow_get_name(r));
}

fn getRange(p: [*c]Pad, offset: u64, size: c.guint, out: [*c][*c]c.GstBuffer) Flow {
    pad.streamLock(p);
    defer pad.streamUnlock(p);
    lock(p);
    if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
        pad.lastFlow(p).* = c.GST_FLOW_FLUSHING;
        unlock(p);
        return c.GST_FLOW_FLUSHING;
    }
    if (p[0].mode != c.GST_PAD_MODE_PULL) {
        pad.lastFlow(p).* = c.GST_FLOW_ERROR;
        unlock(p);
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "getrange on pad %s:%s but it was not activated in pull mode", pad.parentName(p), pad.padName(p));
        return c.GST_FLOW_ERROR;
    }
    var ret = checkSticky(p, null);
    if (ret != c.GST_FLOW_OK) {
        pad.lastFlow(p).* = ret;
        unlock(p);
        return ret;
    }
    var buf = out.*;
    var skip = false;
    const r = pullProbe(p, c.GST_PAD_PROBE_TYPE_PULL | c.GST_PAD_PROBE_TYPE_BLOCK, &buf, offset, size);
    if (r.stop) {
        ret = r.ret;
        if (ret == c.GST_FLOW_CUSTOM_SUCCESS and buf != null) {
            ret = c.GST_FLOW_OK;
            skip = true;
        } else {
            if (ret == c.GST_FLOW_CUSTOM_SUCCESS) ret = c.GST_FLOW_EOS;
            pad.lastFlow(p).* = ret;
            unlock(p);
            return ret;
        }
    }
    if (!skip) {
        ret = checkSticky(p, null);
        if (ret != c.GST_FLOW_OK) {
            pad.lastFlow(p).* = ret;
            unlock(p);
            return ret;
        }
        var parent: [*c]Obj = null;
        if (!pad.acquireParent(p, &parent)) {
            pad.lastFlow(p).* = c.GST_FLOW_FLUSHING;
            unlock(p);
            return c.GST_FLOW_FLUSHING;
        }
        unlock(p);
        const f = p[0].getrangefunc orelse {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "getrange on pad %s:%s but it has no getrangefunction", pad.parentName(p), pad.padName(p));
            pad.releaseParent(parent);
            return c.GST_FLOW_NOT_SUPPORTED;
        };
        ret = f(h(p), parent, offset, size, &buf);
        pad.releaseParent(parent);
        lock(p);
        if (ret != c.GST_FLOW_OK) {
            pad.lastFlow(p).* = ret;
            unlock(p);
            logFail(p, "getrange", ret);
            return ret;
        }
    }
    const after = pullProbe(p, c.GST_PAD_PROBE_TYPE_PULL | c.GST_PAD_PROBE_TYPE_BUFFER, &buf, offset, size);
    if (after.stop) {
        ret = if (after.ret == c.GST_FLOW_CUSTOM_SUCCESS) c.GST_FLOW_EOS else after.ret;
        pad.lastFlow(p).* = ret;
        unlock(p);
        if (out.* == null) c.gst_mini_object_unref(@ptrCast(buf));
        return ret;
    }
    pad.lastFlow(p).* = ret;
    unlock(p);
    if (!check.that(out.* == null or buf == out.*, "gst_pad_get_range_unchecked", "!*buffer || res_buf == *buffer")) return c.GST_FLOW_ERROR;
    out.* = buf;
    return ret;
}

fn rangeArgs(comptime f: []const u8, out: [*c][*c]c.GstBuffer, size: c.guint) bool {
    if (!check.that(out != null, f, "buffer != NULL")) return false;
    return check.that(out.* == null or (isBuffer(out.*) and c.gst_buffer_get_size(out.*) >= size), f, "*buffer == NULL || (GST_IS_BUFFER (*buffer) && gst_buffer_get_size (*buffer) >= size)");
}

pub export fn gst_pad_get_range(p: [*c]Pad, offset: c.guint64, size: c.guint, out: [*c][*c]c.GstBuffer) Flow {
    const f = "gst_pad_get_range";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSrc(p), f, "GST_PAD_IS_SRC (pad)")) return c.GST_FLOW_ERROR;
    if (!rangeArgs(f, out, size)) return c.GST_FLOW_ERROR;
    return getRange(p, offset, size, out);
}

pub export fn gst_pad_pull_range(p: [*c]Pad, offset: c.guint64, size: c.guint, out: [*c][*c]c.GstBuffer) Flow {
    const f = "gst_pad_pull_range";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return c.GST_FLOW_ERROR;
    if (!check.that(isSink(p), f, "GST_PAD_IS_SINK (pad)")) return c.GST_FLOW_ERROR;
    if (!rangeArgs(f, out, size)) return c.GST_FLOW_ERROR;
    lock(p);
    if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
        pad.lastFlow(p).* = c.GST_FLOW_FLUSHING;
        unlock(p);
        return c.GST_FLOW_FLUSHING;
    }
    if (p[0].mode != c.GST_PAD_MODE_PULL) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "pullrange on pad %s:%s but it was not activated in pull mode", pad.parentName(p), pad.padName(p));
        pad.lastFlow(p).* = c.GST_FLOW_ERROR;
        unlock(p);
        return c.GST_FLOW_ERROR;
    }
    var buf = out.*;
    var ret: Flow = c.GST_FLOW_OK;
    var skip = false;
    const r = pullProbe(p, c.GST_PAD_PROBE_TYPE_PULL | c.GST_PAD_PROBE_TYPE_BLOCK, &buf, offset, size);
    if (r.stop) {
        ret = r.ret;
        if (ret == c.GST_FLOW_CUSTOM_SUCCESS and buf != null) {
            ret = c.GST_FLOW_OK;
            skip = true;
        } else {
            if (ret == c.GST_FLOW_CUSTOM_SUCCESS) ret = c.GST_FLOW_EOS;
            pad.lastFlow(p).* = ret;
            unlock(p);
            return ret;
        }
    }
    if (!skip) {
        const peer = p[0].peer;
        if (peer == null) {
            pad.lastFlow(p).* = c.GST_FLOW_NOT_LINKED;
            unlock(p);
            return c.GST_FLOW_NOT_LINKED;
        }
        _ = c.gst_object_ref(peer);
        pad.priv(p).using += 1;
        unlock(p);
        ret = getRange(peer, offset, size, &buf);
        c.gst_object_unref(peer);
        lock(p);
        pad.priv(p).using -= 1;
        pad.lastFlow(p).* = ret;
        if (pad.priv(p).using == 0) {
            if (probeIdle(p, c.GST_PAD_PROBE_TYPE_PULL | c.GST_PAD_PROBE_TYPE_IDLE, ret)) |stopped| {
                ret = if (stopped == c.GST_FLOW_CUSTOM_SUCCESS) c.GST_FLOW_EOS else stopped;
                pad.lastFlow(p).* = ret;
                unlock(p);
                if (out.* == null) c.gst_mini_object_unref(@ptrCast(buf));
                return ret;
            }
        }
        if (ret != c.GST_FLOW_OK) {
            pad.lastFlow(p).* = ret;
            unlock(p);
            logFail(p, "pullrange", ret);
            return ret;
        }
    }
    const after = pullProbe(p, c.GST_PAD_PROBE_TYPE_PULL | c.GST_PAD_PROBE_TYPE_BUFFER, &buf, offset, size);
    if (after.stop) {
        ret = if (after.ret == c.GST_FLOW_CUSTOM_SUCCESS) c.GST_FLOW_EOS else after.ret;
        pad.lastFlow(p).* = ret;
        unlock(p);
        if (out.* == null) c.gst_mini_object_unref(@ptrCast(buf));
        return ret;
    }
    unlock(p);
    out.* = buf;
    return ret;
}

fn storeSticky(p: [*c]Pad, e: [*c]Event) Flow {
    const t = e[0].type;
    const o = pad.order(t);
    if (p[0].mode == c.GST_PAD_MODE_NONE or (has(p, c.GST_PAD_FLAG_FLUSHING) and (t == c.GST_EVENT_SEGMENT or t == c.GST_EVENT_EOS))) return c.GST_FLOW_FLUSHING;
    if (t == c.GST_EVENT_STREAM_START) {
        pad.removeByType(p, c.GST_EVENT_EOS);
        pad.removeByType(p, c.GST_EVENT_STREAM_GROUP_DONE);
        clear(p, c.GST_PAD_FLAG_EOS);
    }
    if (has(p, c.GST_PAD_FLAG_EOS)) return c.GST_FLOW_EOS;
    const name: [*c]const u8 = if (t & c.GST_EVENT_TYPE_STICKY_MULTI != 0) c.gst_structure_get_name(c.gst_event_get_structure(e)) else null;
    var res = false;
    var insert = true;
    var changed = false;
    var i: c.guint = 0;
    const list = pad.events(p);
    while (i < list.len) : (i += 1) {
        const ev = &list[i];
        if (ev.event == null) continue;
        const et = ev.event[0].type;
        if (t == et) {
            if (name != null and c.gst_event_has_name(ev.event, name) == 0) continue;
            if (t == c.GST_EVENT_STREAM_START and e != ev.event) {
                var old_id: [*c]const u8 = null;
                var new_id: [*c]const u8 = null;
                c.gst_event_parse_stream_start(ev.event, &old_id);
                c.gst_event_parse_stream_start(e, &new_id);
                changed = c.g_str_equal(old_id, new_id) == 0;
            }
            res = c.gst_mini_object_replace(@ptrCast(&ev.event), @ptrCast(e)) != 0;
            if (res) ev.received = 0;
            insert = false;
            break;
        }
        if (o < ev.order or (t != et and et == c.GST_EVENT_EOS)) {
            if (ev.order <= pad.order(c.GST_EVENT_SEGMENT) or et == c.GST_EVENT_EOS)
                c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "%s:%s:<%s:%s> Sticky event misordering, got '%s' before '%s'", "../gst/gstpad.c:5803", "store_sticky_event", pad.parentName(p), pad.padName(p), c.gst_event_type_get_name(et), c.gst_event_type_get_name(t));
            break;
        }
    }
    if (insert) {
        var ev = PadEvent{ .order = o, .event = @ptrCast(c.gst_mini_object_ref(@ptrCast(e))), .received = 0 };
        _ = c.g_array_insert_vals(pad.priv(p).events, i, &ev, 1);
        res = true;
        changed = t == c.GST_EVENT_STREAM_START;
    }
    if (changed) pad.removeByType(p, c.GST_EVENT_TAG);
    if (res) {
        pad.priv(p).events_cookie +%= 1;
        set(p, c.GST_PAD_FLAG_PENDING_EVENTS);
        if (t == c.GST_EVENT_CAPS) {
            unlock(p);
            c.g_object_notify_by_pspec(@ptrCast(p), pad.pspec_caps);
            lock(p);
        }
    }
    if (t == c.GST_EVENT_EOS) {
        set(p, c.GST_PAD_FLAG_EOS);
        pad.lastFlow(p).* = c.GST_FLOW_EOS;
    }
    return if (has(p, c.GST_PAD_FLAG_FLUSHING)) c.GST_FLOW_FLUSHING else c.GST_FLOW_OK;
}

fn isEvent(e: [*c]Event) bool {
    return e != null and e[0].mini_object.type == c._gst_event_type;
}

pub export fn gst_pad_store_sticky_event(p: [*c]Pad, e: [*c]Event) Flow {
    if (!check.that(pad.isPad(p), "gst_pad_store_sticky_event", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isEvent(e), "gst_pad_store_sticky_event", "GST_IS_EVENT (event)")) return 0;
    lock(p);
    defer unlock(p);
    return storeSticky(p, e);
}

fn stickyChanged(p: [*c]Pad, ev: *PadEvent, data: ?*anyopaque) bool {
    const d: *Sticky = @ptrCast(@alignCast(data));
    if (ev.event != d.event and ev.order < pad.order(d.event[0].type)) return pushSticky(p, ev, data);
    return true;
}

fn flushStop(p: [*c]Pad) void {
    clear(p, c.GST_PAD_FLAG_FLUSHING);
    pad.removeByType(p, c.GST_EVENT_EOS);
    pad.removeByType(p, c.GST_EVENT_STREAM_GROUP_DONE);
    pad.removeByType(p, c.GST_EVENT_SEGMENT);
    clear(p, c.GST_PAD_FLAG_EOS);
    pad.lastFlow(p).* = c.GST_FLOW_OK;
}

fn pushEventUnchecked(p: [*c]Pad, e_in: [*c]Event, kind_in: c.GstPadProbeType) Flow {
    var kind = kind_in;
    const old_offset = p[0].offset;
    var e = pad.applyOffset(p, e_in, isSink(p));
    const t = e[0].type;
    var data: c.gpointer = e;
    switch (t) {
        c.GST_EVENT_FLUSH_START => {
            set(p, c.GST_PAD_FLAG_FLUSHING);
            pad.blockBroadcast(p);
            kind |= c.GST_PAD_PROBE_TYPE_EVENT_FLUSH;
        },
        c.GST_EVENT_FLUSH_STOP => {
            if (p[0].mode == c.GST_PAD_MODE_NONE) {
                c.gst_mini_object_unref(@ptrCast(e));
                return c.GST_FLOW_FLUSHING;
            }
            flushStop(p);
            kind |= c.GST_PAD_PROBE_TYPE_EVENT_FLUSH;
        },
        else => {
            if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
                c.gst_mini_object_unref(@ptrCast(e));
                return c.GST_FLOW_FLUSHING;
            }
            if (t == c.GST_EVENT_RECONFIGURE) {
                if (isSink(p)) set(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
                if (pad.lastFlow(p).* == c.GST_FLOW_NOT_LINKED) pad.lastFlow(p).* = c.GST_FLOW_OK;
            }
            const r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_BLOCK, &data, NONE64, NONE32, false);
            if (r.stop) return pushProbeStopped(p, data, r.ret);
            e = @ptrCast(@alignCast(data));
            if (has(p, c.GST_PAD_FLAG_PENDING_EVENTS) and isSrc(p) and isSerialized(e)) {
                var d = Sticky{ .ret = c.GST_FLOW_OK, .was_eos = false, .event = e };
                clear(p, c.GST_PAD_FLAG_PENDING_EVENTS);
                pad.eachEvent(p, stickyChanged, &d);
            }
        },
    }
    const r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH, &data, NONE64, NONE32, false);
    if (r.stop) return pushProbeStopped(p, data, r.ret);
    e = @ptrCast(@alignCast(data));
    if (has(p, c.GST_PAD_FLAG_PENDING_EVENTS) and isSrc(p) and isSerialized(e) and e[0].type != c.GST_EVENT_FLUSH_STOP) {
        var d = Sticky{ .ret = c.GST_FLOW_OK, .was_eos = false, .event = e };
        clear(p, c.GST_PAD_FLAG_PENDING_EVENTS);
        pad.eachEvent(p, stickyChanged, &d);
    }
    if (old_offset != p[0].offset) e = pad.offsetEvent(e, isSink(p), p[0].offset - old_offset);
    const peer = p[0].peer;
    if (peer == null) {
        set(p, c.GST_PAD_FLAG_PENDING_EVENTS);
        c.gst_mini_object_unref(@ptrCast(e));
        return if (t == c.GST_EVENT_LATENCY) c.GST_FLOW_OK else c.GST_FLOW_NOT_LINKED;
    }
    _ = c.gst_object_ref(peer);
    pad.priv(p).using += 1;
    unlock(p);
    const ret = sendEventUnchecked(peer, e, kind);
    c.gst_object_unref(peer);
    lock(p);
    pad.priv(p).using -= 1;
    if (pad.priv(p).using == 0) {
        if (probeIdle(p, c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_IDLE, ret)) |stopped| return stopped;
    }
    return ret;
}

fn pushProbeStopped(p: [*c]Pad, data: c.gpointer, ret: Flow) Flow {
    set(p, c.GST_PAD_FLAG_PENDING_EVENTS);
    if (data != null and ret != SUCCESS_1) dropData(data);
    return ret;
}

fn eventDirection(comptime f: []const u8, comptime verb: []const u8, p: [*c]Pad, e: [*c]Event) bool {
    _ = f;
    c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "pad %s:%s " ++ verb ++ " %s event in wrong direction", pad.parentName(p), pad.padName(p), c.gst_event_type_get_name(e[0].type));
    c.gst_mini_object_unref(@ptrCast(e));
    return false;
}

pub export fn gst_pad_push_event(p: [*c]Pad, e: [*c]Event) c.gboolean {
    if (!check.that(pad.isPad(p), "gst_pad_push_event", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isEvent(e), "gst_pad_push_event", "GST_IS_EVENT (event)")) return 0;
    var kind: c.GstPadProbeType = undefined;
    if (isSrc(p)) {
        if (e[0].type & c.GST_EVENT_TYPE_DOWNSTREAM == 0) return @intFromBool(eventDirection("gst_pad_push_event", "pushing", p, e));
        kind = c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM;
    } else if (isSink(p)) {
        if (e[0].type & c.GST_EVENT_TYPE_UPSTREAM == 0) return @intFromBool(eventDirection("gst_pad_push_event", "pushing", p, e));
        kind = c.GST_PAD_PROBE_TYPE_EVENT_UPSTREAM;
    } else {
        _ = badDirection(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return 0;
    }
    lock(p);
    const sticky = isSticky(e);
    const serialized = isSerialized(e);
    if (sticky) {
        const s = storeSticky(p, e);
        if (s == c.GST_FLOW_FLUSHING or s == c.GST_FLOW_EOS) {
            unlock(p);
            c.gst_mini_object_unref(@ptrCast(e));
            return 0;
        }
    }
    var res = false;
    if (isSrc(p) and serialized and e[0].type != c.GST_EVENT_FLUSH_STOP) res = checkSticky(p, e) == c.GST_FLOW_OK;
    if (!serialized or !sticky) {
        const r = pushEventUnchecked(p, e, kind);
        res = r == c.GST_FLOW_OK or r == c.GST_FLOW_CUSTOM_SUCCESS or r == SUCCESS_1;
    } else {
        if (e[0].type != c.GST_EVENT_EOS) res = true;
        c.gst_mini_object_unref(@ptrCast(e));
    }
    unlock(p);
    return @intFromBool(res);
}

fn preEventCheck(p: [*c]Pad, e: [*c]Event) Flow {
    if (e[0].type != c.GST_EVENT_CAPS) return c.GST_FLOW_OK;
    var caps: [*c]Caps = null;
    c.gst_event_parse_caps(e, &caps);
    return if (gst_pad_query_accept_caps(p, caps) != 0) c.GST_FLOW_OK else c.GST_FLOW_NOT_NEGOTIATED;
}

fn sendEventUnchecked(p: [*c]Pad, e_in: [*c]Event, kind_in: c.GstPadProbeType) Flow {
    var kind = kind_in;
    var need_unlock = false;
    lock(p);
    const old_offset = p[0].offset;
    var e = pad.applyOffset(p, e_in, isSrc(p));
    const serialized = isSink(p) and isSerialized(e);
    const sticky = isSticky(e);
    const t = e[0].type;
    const Bail = enum { flushing, eos };
    var bail: ?Bail = null;
    sw: switch (t) {
        c.GST_EVENT_FLUSH_START => {
            if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
                bail = .flushing;
                break :sw;
            }
            set(p, c.GST_PAD_FLAG_FLUSHING);
            pad.blockBroadcast(p);
            kind |= c.GST_PAD_PROBE_TYPE_EVENT_FLUSH;
        },
        c.GST_EVENT_FLUSH_STOP => {
            if (p[0].mode == c.GST_PAD_MODE_NONE) {
                bail = .flushing;
                break :sw;
            }
            flushStop(p);
            unlock(p);
            pad.streamLock(p);
            need_unlock = true;
            lock(p);
            if (has(p, c.GST_PAD_FLAG_FLUSHING)) bail = .flushing;
        },
        else => {
            if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
                bail = .flushing;
                break :sw;
            }
            switch (t) {
                c.GST_EVENT_STREAM_START => {
                    unlock(p);
                    pad.streamLock(p);
                    need_unlock = true;
                    lock(p);
                    if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
                        bail = .flushing;
                        break :sw;
                    }
                    var changed = true;
                    for (pad.events(p)) |*ev| {
                        if (ev.event[0].type != c.GST_EVENT_STREAM_START) continue;
                        if (ev.event == e) {
                            changed = false;
                            break;
                        }
                        var old_id: [*c]const u8 = null;
                        var new_id: [*c]const u8 = null;
                        c.gst_event_parse_stream_start(ev.event, &old_id);
                        c.gst_event_parse_stream_start(e, &new_id);
                        changed = c.g_str_equal(old_id, new_id) == 0;
                        break;
                    }
                    pad.removeByType(p, c.GST_EVENT_EOS);
                    pad.removeByType(p, c.GST_EVENT_STREAM_GROUP_DONE);
                    clear(p, c.GST_PAD_FLAG_EOS);
                    if (changed) pad.removeByType(p, c.GST_EVENT_TAG);
                },
                c.GST_EVENT_RECONFIGURE => {
                    if (isSrc(p)) set(p, c.GST_PAD_FLAG_NEED_RECONFIGURE);
                    if (pad.lastFlow(p).* == c.GST_FLOW_NOT_LINKED) pad.lastFlow(p).* = c.GST_FLOW_OK;
                },
                else => if (serialized) {
                    unlock(p);
                    pad.streamLock(p);
                    need_unlock = true;
                    lock(p);
                    if (has(p, c.GST_PAD_FLAG_FLUSHING)) {
                        bail = .flushing;
                    } else if (has(p, c.GST_PAD_FLAG_EOS)) bail = .eos;
                },
            }
        },
    }
    if (bail) |b| {
        unlock(p);
        if (need_unlock) pad.streamUnlock(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return if (b == .eos) c.GST_FLOW_EOS else c.GST_FLOW_FLUSHING;
    }
    var data: c.gpointer = e;
    var r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH | c.GST_PAD_PROBE_TYPE_BLOCK, &data, NONE64, NONE32, false);
    if (!r.stop) r = probe(p, kind | c.GST_PAD_PROBE_TYPE_PUSH, &data, NONE64, NONE32, false);
    if (r.stop) {
        unlock(p);
        if (need_unlock) pad.streamUnlock(p);
        if (data != null and r.ret != SUCCESS_1) dropData(data);
        return foldStop(r.ret);
    }
    e = @ptrCast(@alignCast(data));
    if (old_offset != p[0].offset) e = pad.offsetEvent(e, isSrc(p), p[0].offset - old_offset);
    const full = p[0].ABI.abi.eventfullfunc;
    const func = p[0].eventfunc;
    if (func == null and full == null) {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "pad %s:%s has no event handler, file a bug.", pad.parentName(p), pad.padName(p));
        unlock(p);
        if (need_unlock) pad.streamUnlock(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return c.GST_FLOW_NOT_SUPPORTED;
    }
    var parent: [*c]Obj = null;
    if (!pad.acquireParent(p, &parent)) {
        unlock(p);
        if (need_unlock) pad.streamUnlock(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return c.GST_FLOW_FLUSHING;
    }
    unlock(p);
    var ret = preEventCheck(p, e);
    if (ret != c.GST_FLOW_OK) {
        pad.releaseParent(parent);
        if (need_unlock) pad.streamUnlock(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return ret;
    }
    if (sticky) _ = c.gst_mini_object_ref(@ptrCast(e));
    if (full) |ff| {
        ret = ff(h(p), parent, e);
    } else if (func.?(h(p), parent, e) != 0) {
        ret = c.GST_FLOW_OK;
    } else ret = if (t == c.GST_EVENT_CAPS) c.GST_FLOW_NOT_NEGOTIATED else c.GST_FLOW_ERROR;
    pad.releaseParent(parent);
    if (sticky) {
        if (ret == c.GST_FLOW_OK) {
            lock(p);
            const s = storeSticky(p, e);
            if (s == c.GST_FLOW_FLUSHING or s == c.GST_FLOW_EOS) {
                unlock(p);
                if (need_unlock) pad.streamUnlock(p);
                c.gst_mini_object_unref(@ptrCast(e));
                return s;
            }
            unlock(p);
        }
        c.gst_mini_object_unref(@ptrCast(e));
    }
    if (need_unlock) pad.streamUnlock(p);
    return ret;
}

pub export fn gst_pad_send_event(p: [*c]Pad, e: [*c]Event) c.gboolean {
    if (!check.that(pad.isPad(p), "gst_pad_send_event", "GST_IS_PAD (pad)")) return 0;
    if (!check.that(e != null, "gst_pad_send_event", "event != NULL")) return 0;
    var kind: c.GstPadProbeType = undefined;
    if (isSink(p)) {
        if (e[0].type & c.GST_EVENT_TYPE_DOWNSTREAM == 0) return @intFromBool(eventDirection("gst_pad_send_event", "sending", p, e));
        kind = c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM;
    } else if (isSrc(p)) {
        if (e[0].type & c.GST_EVENT_TYPE_UPSTREAM == 0) return @intFromBool(eventDirection("gst_pad_send_event", "sending", p, e));
        kind = c.GST_PAD_PROBE_TYPE_EVENT_UPSTREAM;
    } else {
        _ = badDirection(p);
        c.gst_mini_object_unref(@ptrCast(e));
        return 0;
    }
    return @intFromBool(sendEventUnchecked(p, e, kind) == c.GST_FLOW_OK);
}

const AcceptData = struct { query: [*c]Query, ret: c.gboolean };

fn acceptForward(raw: Raw, data: c.gpointer) callconv(.c) c.gboolean {
    const p = of(raw);
    const d: *AcceptData = @ptrCast(@alignCast(data));
    if (gst_pad_peer_query(p, d.query) != 0) {
        var r: c.gboolean = 0;
        c.gst_query_parse_accept_caps_result(d.query, &r);
        d.ret &= r;
    }
    return 0;
}

pub export fn gst_pad_proxy_query_accept_caps(p: [*c]Pad, q: [*c]Query) c.gboolean {
    const f = "gst_pad_proxy_query_accept_caps";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isQuery(q), f, "GST_IS_QUERY (query)")) return 0;
    if (!check.that(q[0].type == c.GST_QUERY_ACCEPT_CAPS, f, "GST_QUERY_TYPE (query) == GST_QUERY_ACCEPT_CAPS")) return 0;
    var d = AcceptData{ .query = q, .ret = 1 };
    _ = pad.gst_pad_forward(p, acceptForward, &d);
    c.gst_query_set_accept_caps_result(q, d.ret);
    return d.ret;
}

const CapsData = struct { query: [*c]Query, ret: [*c]Caps };

fn capsForward(raw: Raw, data: c.gpointer) callconv(.c) c.gboolean {
    const p = of(raw);
    const d: *CapsData = @ptrCast(@alignCast(data));
    if (gst_pad_peer_query(p, d.query) == 0) return 0;
    var peer: [*c]Caps = null;
    c.gst_query_parse_caps_result(d.query, &peer);
    const x = c.gst_caps_intersect(d.ret, peer);
    c.gst_caps_unref(d.ret);
    d.ret = x;
    return c.gst_caps_is_empty(x);
}

pub export fn gst_pad_proxy_query_caps(p: [*c]Pad, q: [*c]Query) c.gboolean {
    const f = "gst_pad_proxy_query_caps";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isQuery(q), f, "GST_IS_QUERY (query)")) return 0;
    if (!check.that(q[0].type == c.GST_QUERY_CAPS, f, "GST_QUERY_TYPE (query) == GST_QUERY_CAPS")) return 0;
    var filter: [*c]Caps = null;
    c.gst_query_parse_caps(q, &filter);
    var d = CapsData{ .query = q, .ret = if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any() };
    _ = pad.gst_pad_forward(p, capsForward, &d);
    const templ = pad.gst_pad_get_pad_template_caps(p);
    const result = c.gst_caps_intersect(d.ret, templ);
    c.gst_caps_unref(d.ret);
    c.gst_caps_unref(templ);
    c.gst_query_set_caps_result(q, result);
    c.gst_caps_unref(result);
    return 1;
}

fn queryPosition(comptime f: []const u8, comptime peer: bool, p: [*c]Pad, format: c.GstFormat, cur: [*c]c.gint64) c.gboolean {
    if (cur != null) cur.* = -1;
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(format != c.GST_FORMAT_UNDEFINED, f, "format != GST_FORMAT_UNDEFINED")) return 0;
    const q = c.gst_query_new_position(format);
    const ok = if (peer) gst_pad_peer_query(p, q) else gst_pad_query(p, q);
    if (ok != 0) c.gst_query_parse_position(q, null, cur);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_pad_query_position(p: [*c]Pad, format: c.GstFormat, cur: [*c]c.gint64) c.gboolean {
    return queryPosition("gst_pad_query_position", false, p, format, cur);
}

pub export fn gst_pad_peer_query_position(p: [*c]Pad, format: c.GstFormat, cur: [*c]c.gint64) c.gboolean {
    return queryPosition("gst_pad_peer_query_position", true, p, format, cur);
}

pub export fn gst_pad_query_duration(p: [*c]Pad, format: c.GstFormat, dur: [*c]c.gint64) c.gboolean {
    const f = "gst_pad_query_duration";
    if (dur != null) dur.* = -1;
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(format != c.GST_FORMAT_UNDEFINED, f, "format != GST_FORMAT_UNDEFINED")) return 0;
    const q = c.gst_query_new_duration(format);
    const ok = gst_pad_query(p, q);
    if (ok != 0) c.gst_query_parse_duration(q, null, dur);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_pad_peer_query_duration(p: [*c]Pad, format: c.GstFormat, dur: [*c]c.gint64) c.gboolean {
    const f = "gst_pad_peer_query_duration";
    if (dur != null) dur.* = -1;
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isSink(p), f, "GST_PAD_IS_SINK (pad)")) return 0;
    if (!check.that(format != c.GST_FORMAT_UNDEFINED, f, "format != GST_FORMAT_UNDEFINED")) return 0;
    const q = c.gst_query_new_duration(format);
    const ok = gst_pad_peer_query(p, q);
    if (ok != 0) c.gst_query_parse_duration(q, null, dur);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_pad_query_convert(p: [*c]Pad, src_format: c.GstFormat, src_val: c.gint64, dest_format: c.GstFormat, dest_val: [*c]c.gint64) c.gboolean {
    const f = "gst_pad_query_convert";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(dest_format != c.GST_FORMAT_UNDEFINED, f, "dest_format != GST_FORMAT_UNDEFINED")) return 0;
    if (!check.that(dest_val != null, f, "dest_val != NULL")) return 0;
    if (dest_format == src_format or src_val == -1) {
        dest_val.* = src_val;
        return 1;
    }
    dest_val.* = -1;
    const q = c.gst_query_new_convert(src_format, src_val, dest_format);
    const ok = gst_pad_query(p, q);
    if (ok != 0) c.gst_query_parse_convert(q, null, null, null, dest_val);
    c.gst_query_unref(q);
    return ok;
}

pub export fn gst_pad_peer_query_convert(p: [*c]Pad, src_format: c.GstFormat, src_val: c.gint64, dest_format: c.GstFormat, dest_val: [*c]c.gint64) c.gboolean {
    const f = "gst_pad_peer_query_convert";
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isSink(p), f, "GST_PAD_IS_SINK (pad)")) return 0;
    if (!check.that(dest_format != c.GST_FORMAT_UNDEFINED, f, "dest_format != GST_FORMAT_UNDEFINED")) return 0;
    if (!check.that(dest_val != null, f, "dest_val != NULL")) return 0;
    dest_val.* = -1;
    const q = c.gst_query_new_convert(src_format, src_val, dest_format);
    const ok = gst_pad_peer_query(p, q);
    if (ok != 0) c.gst_query_parse_convert(q, null, null, null, dest_val);
    c.gst_query_unref(q);
    return ok;
}

fn isCaps(caps: [*c]Caps) bool {
    return caps != null and caps[0].mini_object.type == c._gst_caps_type;
}

fn queryCaps(comptime f: []const u8, comptime peer: bool, p: [*c]Pad, filter: [*c]Caps) [*c]Caps {
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return null;
    if (!check.that(filter == null or isCaps(filter), f, "filter == NULL || GST_IS_CAPS (filter)")) return null;
    const q = c.gst_query_new_caps(filter);
    var result: [*c]Caps = null;
    const ok = if (peer) gst_pad_peer_query(p, q) else gst_pad_query(p, q);
    if (ok != 0) {
        c.gst_query_parse_caps_result(q, &result);
        _ = c.gst_caps_ref(result);
    } else result = if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any();
    c.gst_query_unref(q);
    return result;
}

pub export fn gst_pad_query_caps(p: [*c]Pad, filter: [*c]Caps) [*c]Caps {
    return queryCaps("gst_pad_query_caps", false, p, filter);
}

pub export fn gst_pad_peer_query_caps(p: [*c]Pad, filter: [*c]Caps) [*c]Caps {
    return queryCaps("gst_pad_peer_query_caps", true, p, filter);
}

fn acceptCaps(comptime f: []const u8, comptime peer: bool, p: [*c]Pad, caps: [*c]Caps) c.gboolean {
    if (!check.that(pad.isPad(p), f, "GST_IS_PAD (pad)")) return 0;
    if (!check.that(isCaps(caps), f, "GST_IS_CAPS (caps)")) return 0;
    const q = c.gst_query_new_accept_caps(caps);
    var res: c.gboolean = 1;
    const ok = if (peer) gst_pad_peer_query(p, q) else gst_pad_query(p, q);
    if (ok != 0) c.gst_query_parse_accept_caps_result(q, &res);
    c.gst_query_unref(q);
    return res;
}

pub export fn gst_pad_query_accept_caps(p: [*c]Pad, caps: [*c]Caps) c.gboolean {
    return acceptCaps("gst_pad_query_accept_caps", false, p, caps);
}

pub export fn gst_pad_peer_query_accept_caps(p: [*c]Pad, caps: [*c]Caps) c.gboolean {
    return acceptCaps("gst_pad_peer_query_accept_caps", true, p, caps);
}
