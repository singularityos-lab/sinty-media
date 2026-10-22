const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const utils = @import("utils.zig");

const FILE = "../gst/playback/gstparsebin.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;

const PROP_SUBTITLE_ENCODING = 1;
const PROP_SINK_CAPS = 2;
const PROP_EXPOSE_ALL_STREAMS = 3;
const PROP_CONNECTION_SPEED = 4;

const SIG_UNKNOWN_TYPE = 0;
const SIG_AUTOPLUG_CONTINUE = 1;
const SIG_AUTOPLUG_FACTORIES = 2;
const SIG_AUTOPLUG_SELECT = 3;
const SIG_AUTOPLUG_SORT = 4;
const SIG_AUTOPLUG_QUERY = 5;
const SIG_DRAINED = 6;

const Elem = struct {
    element: ?*c.GstElement,
    capsfilter: ?*c.GstElement = null,
    added_id: c.gulong = 0,
    removed_id: c.gulong = 0,
    nmp_id: c.gulong = 0,
};

const Pending = struct {
    pad: ?*c.GstPad,
    chain: *Chain,
    probe: c.gulong = 0,
    caps_id: c.gulong = 0,
};

const Group = struct {
    bin: *Self,
    parent: ?*Chain,
    no_more_pads: bool = false,
    drained: bool = false,
    children: [*c]c.GList = null,
};

const Chain = struct {
    parent: ?*Group,
    bin: *Self,
    lock: c.GMutex = undefined,
    pad: ?*c.GstPad = null,
    start_caps: [*c]c.GstCaps = null,
    drained: bool = false,
    demuxer: bool = false,
    parsed: bool = false,
    elements: [*c]c.GList = null,
    active_group: ?*Group = null,
    next_groups: [*c]c.GList = null,
    pending_pads: [*c]c.GList = null,
    current_pad: ?*PPad = null,
    endpad: ?*PPad = null,
    deadend: bool = false,
    deadend_details: [*c]u8 = null,
    endcaps: [*c]c.GstCaps = null,
    old_groups: [*c]c.GList = null,
};

const Ghost = extern struct {
    pad: cm.Pad,
    proxy_priv: ?*anyopaque,
    ghost_priv: ?*anyopaque,
};

const GhostClass = extern struct {
    parent: c.GstPadClass,
    proxy_reserved: [1]c.gpointer,
    reserved: [4]c.gpointer,
};

pub const PPad = extern struct {
    parent: Ghost,
    bin: ?*Self,
    chain: ?*anyopaque,
    blocked: c.gboolean,
    exposed: c.gboolean,
    drained: c.gboolean,
    block_id: c.gulong,
    in_fallback: c.gboolean,
    active_collection: ?*c.GstStreamCollection,
    active_stream: ?*c.GstStream,
};

pub const Self = extern struct {
    parent: c.GstBin,
    encoding: [*c]u8,
    speed: u64,
    typefind: ?*c.GstElement,
    expose_lock: c.GMutex,
    chain: ?*anyopaque,
    nbpads: c.guint,
    factories_lock: c.GMutex,
    cookie: u32,
    factories: [*c]c.GList,
    subtitle_lock: c.GMutex,
    subtitles: [*c]c.GList,
    have_type: c.gboolean,
    have_type_id: c.gulong,
    dyn_lock: c.GMutex,
    shutdown: c.gboolean,
    blocked_pads: [*c]c.GList,
    expose_all: c.gboolean,
    filtered: [*c]c.GList,
    filtered_errors: [*c]c.GList,
    cleanup_lock: c.GMutex,
    cleanup_thread: ?*c.GThread,
};

const Class = extern struct {
    parent: c.GstBinClass,
    unknown_type: ?*const fn (?*c.GstElement, ?*c.GstPad, [*c]c.GstCaps) callconv(.c) void,
    autoplug_continue: ?*const fn (?*c.GstElement, ?*c.GstPad, [*c]c.GstCaps) callconv(.c) c.gboolean,
    autoplug_factories: ?*const fn (?*c.GstElement, ?*c.GstPad, [*c]c.GstCaps) callconv(.c) [*c]c.GValueArray,
    autoplug_sort: ?*const fn (?*c.GstElement, ?*c.GstPad, [*c]c.GstCaps, [*c]c.GValueArray) callconv(.c) [*c]c.GValueArray,
    autoplug_select: ?*const fn (?*c.GstElement, ?*c.GstPad, [*c]c.GstCaps, ?*c.GstElementFactory) callconv(.c) c.gint,
    autoplug_query: ?*const fn (?*c.GstElement, ?*c.GstPad, ?*c.GstQuery) callconv(.c) c.gboolean,
    drained: ?*const fn (?*c.GstElement) callconv(.c) void,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var signals: [7]c.guint = .{ 0, 0, 0, 0, 0, 0, 0 };
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;
var pad_parent: ?*c.GObjectClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn ppad(p: anytype) *PPad {
    return @ptrCast(@alignCast(p));
}

fn chainOf(p: *PPad) *Chain {
    return @ptrCast(@alignCast(p.chain.?));
}

fn rootChain(s: *Self) ?*Chain {
    return @ptrCast(@alignCast(s.chain));
}

fn elem(p: anytype) *c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn binOf(p: anytype) *c.GstBin {
    return @ptrCast(@alignCast(p));
}

fn gobj(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

fn padOf(p: anytype) ?*c.GstPad {
    return @ptrCast(@alignCast(p));
}

fn ghost(p: anytype) ?*c.GstGhostPad {
    return @ptrCast(@alignCast(p));
}

fn ref(p: anytype) @TypeOf(p) {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn chainLock(ch: *Chain) void {
    c.g_mutex_lock(&ch.lock);
}

fn chainUnlock(ch: *Chain) void {
    c.g_mutex_unlock(&ch.lock);
}

fn exposeLock(s: *Self) void {
    c.g_mutex_lock(&s.expose_lock);
}

fn exposeUnlock(s: *Self) void {
    c.g_mutex_unlock(&s.expose_lock);
}

fn dynLock(s: *Self) void {
    c.g_mutex_lock(&s.dyn_lock);
}

fn dynUnlock(s: *Self) void {
    c.g_mutex_unlock(&s.dyn_lock);
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, s);
}

fn firstElem(ch: *Chain) ?*Elem {
    if (ch.elements == null) return null;
    return @ptrCast(@alignCast(ch.elements.*.data));
}

fn klassOf(f: ?*c.GstElementFactory) [*c]const u8 {
    return c.gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS);
}

fn hasText(hay: [*c]const u8, needle: [*c]const u8) bool {
    return hay != null and c.strstr(hay, needle) != null;
}

fn boolAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const v = c.g_value_get_boolean(ret);
    c.g_value_set_boolean(accu, v);
    return v;
}

fn boolOrAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const v = c.g_value_get_boolean(ret) != 0 or c.g_value_get_boolean(accu) != 0;
    c.g_value_set_boolean(accu, @intFromBool(v));
    return 1;
}

fn arrayAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    c.g_value_set_boxed(accu, c.g_value_get_boxed(ret));
    return 0;
}

fn selectAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const v = c.g_value_get_enum(ret);
    c.g_value_set_enum(accu, v);
    return @intFromBool(v == flags.SELECT_TRY);
}

fn arrayHasValueAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const a = c.g_value_get_boxed(ret);
    c.g_value_set_boxed(accu, a);
    return @intFromBool(a == null);
}

fn updateFactories(s: *Self) void {
    const cookie = c.gst_registry_get_feature_list_cookie(c.gst_registry_get());
    if (s.factories != null and s.cookie == cookie) return;
    if (s.factories != null) c.gst_plugin_feature_list_free(s.factories);
    s.factories = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODABLE, c.GST_RANK_MARGINAL);
    s.factories = c.g_list_sort(s.factories, utils.compareFactories);
    s.cookie = cookie;
}

fn sinkQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = me(parent);
    if (rootChain(s)) |ch| if (cm.queryType(q) == c.GST_QUERY_ACCEPT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_query_parse_accept_caps(q, &caps);
        if (caps != null) c.gst_query_set_accept_caps_result(q, @intFromBool(chainAcceptCaps(ch, caps)));
        return 1;
    };
    return c.gst_pad_query_default(pad, cm.obj(s), q);
}

fn autoplugContinue(_: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const raw = utils.rawCaps();
    return @intFromBool(c.gst_caps_can_intersect(caps, raw) == 0);
}

fn autoplugFactories(e: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GValueArray {
    const s = me(e);
    c.g_mutex_lock(&s.factories_lock);
    updateFactories(s);
    const list = c.gst_element_factory_list_filter(s.factories, caps, c.GST_PAD_SINK, c.gst_caps_is_fixed(caps));
    c.g_mutex_unlock(&s.factories_lock);
    const res = c.g_value_array_new(c.g_list_length(list));
    var l = list;
    while (l != null) : (l = l.*.next) {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.G_TYPE_OBJECT);
        c.g_value_set_object(&v, l.*.data);
        _ = c.g_value_array_append(res, &v);
        c.g_value_unset(&v);
    }
    c.gst_plugin_feature_list_free(list);
    return res;
}

fn autoplugSort(_: ?*c.GstElement, _: ?*c.GstPad, _: [*c]c.GstCaps, _: [*c]c.GValueArray) callconv(.c) [*c]c.GValueArray {
    return null;
}

fn autoplugSelect(_: ?*c.GstElement, _: ?*c.GstPad, _: [*c]c.GstCaps, _: ?*c.GstElementFactory) callconv(.c) c.gint {
    return flags.SELECT_TRY;
}

fn autoplugQuery(_: ?*c.GstElement, _: ?*c.GstPad, _: ?*c.GstQuery) callconv(.c) c.gboolean {
    return 0;
}

fn clearSticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_event_unref(ev.*);
    ev.* = null;
    return 1;
}

fn copySticky(_: ?*c.GstPad, evp: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const p = ppad(data);
    var ev = c.gst_event_ref(evp.*);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            updateCaps(p, caps);
        },
        c.GST_EVENT_STREAM_START => ev = streamStart(p, ev),
        c.GST_EVENT_STREAM_COLLECTION => {
            var col: ?*c.GstStreamCollection = null;
            c.gst_event_parse_stream_collection(ev, &col);
            updateCollection(p, col);
            c.gst_object_unref(col);
        },
        else => {},
    }
    _ = c.gst_pad_store_sticky_event(padOf(p), ev);
    c.gst_event_unref(ev);
    return 1;
}

fn setTarget(p: *PPad, target: ?*c.GstPad) void {
    const old = c.gst_ghost_pad_get_target(ghost(p));
    if (old) |x| c.gst_object_unref(x);
    if (old == target) return;
    _ = c.gst_pad_sticky_events_foreach(padOf(p), clearSticky, null);
    _ = c.gst_ghost_pad_set_target(ghost(p), target);
    if (target != null) _ = c.gst_pad_sticky_events_foreach(target, copySticky, p);
}

fn delayPad(ch: *Chain, pad: ?*c.GstPad) void {
    chainLock(ch);
    const pp = A.create(Pending) catch @panic("oom");
    pp.* = .{ .pad = ref(pad.?), .chain = ch };
    pp.probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, pendingEvent, pp, null);
    ch.pending_pads = c.g_list_prepend(ch.pending_pads, pp);
    pp.caps_id = c.g_signal_connect_data(pad, "notify::caps", @ptrCast(&capsNotify), ch, null, 0);
    chainUnlock(ch);
}

fn exposeIfComplete(s: *Self) void {
    exposeLock(s);
    if (rootChain(s)) |root| if (chainIsComplete(root)) {
        _ = expose(s);
    };
    exposeUnlock(s);
}

fn analyzeNewPad(s: *Self, src: ?*c.GstElement, pad_in: ?*c.GstPad, caps_in: [*c]c.GstCaps, chain_in: *Chain) void {
    var chain = chain_in;
    var pad = pad_in;
    if (firstElem(chain)) |first| {
        if (src != first.element and src != first.capsfilter) return;
    }
    if (chain.demuxer) {
        const old = chain;
        const demux = firstElem(chain);
        if (chain.current_pad) |p| c.gst_object_unref(p);
        chain.current_pad = null;
        chainLock(old);
        const group = currentGroup(chain);
        if (c.g_list_find(group.children, chain) == null) {
            chain = newChain(s, group, pad, caps_in);
            group.children = c.g_list_prepend(group.children, chain);
        }
        chainUnlock(old);
        if (demux == null or demux.?.nmp_id == 0) group.no_more_pads = true;
    }
    var caps = caps_in;
    if (caps != null) _ = c.gst_caps_ref(caps);
    var parsepad: ?*PPad = null;
    var is_pc = false;
    var details: [*c]u8 = null;
    var factories: [*c]c.GValueArray = null;
    const Next = enum { done, expose, unknown, delay };
    const next: Next = blk: {
        if (caps == null or c.gst_caps_is_empty(caps) != 0) break :blk .unknown;
        if (c.gst_caps_is_any(caps) != 0) break :blk .delay;
        if (chain.current_pad == null) chain.current_pad = newPad(s, chain);
        parsepad = ref(chain.current_pad.?);
        _ = c.gst_pad_set_active(padOf(parsepad), 1);
        setTarget(parsepad.?, pad);
        const fixed = c.gst_caps_is_fixed(caps) != 0;
        if (fixed) updateCaps(parsepad.?, caps);
        var go: c.gboolean = 1;
        if (fixed) c.g_signal_emit(s, signals[SIG_AUTOPLUG_CONTINUE], 0, parsepad, caps, &go);
        if (go == 0) break :blk .expose;
        const classification = klassOf(c.gst_element_get_factory(src));
        is_pc = hasText(classification, "Parser") and hasText(classification, "Converter");
        if (!is_pc and !fixed) {
            c.gst_object_unref(parsepad);
            parsepad = null;
            break :blk .delay;
        } else if (!is_pc) {
            c.gst_caps_unref(caps);
            caps = c.gst_pad_get_current_caps(pad);
            if (caps == null) {
                c.gst_object_unref(parsepad);
                parsepad = null;
                break :blk .delay;
            }
        }
        c.g_signal_emit(s, signals[SIG_AUTOPLUG_FACTORIES], 0, parsepad, caps, &factories);
        if (factories == null) break :blk .expose;
        if (factories.*.n_values == 0) {
            c.g_value_array_free(factories);
            factories = null;
            if (s.expose_all == 0) break :blk .unknown;
            const p = parsepad.?;
            if (p.in_fallback != 0) {
                const ns = c.gst_stream_new(c.gst_stream_get_stream_id(p.active_stream), caps, c.GST_STREAM_TYPE_UNKNOWN, c.gst_stream_get_stream_flags(p.active_stream));
                _ = c.gst_object_replace(@ptrCast(&p.active_stream), cm.obj(ns));
            }
            _ = c.gst_element_post_message(elem(s), c.gst_missing_decoder_message_new(elem(s), caps));
            break :blk .expose;
        }
        var sorted: [*c]c.GValueArray = null;
        c.g_signal_emit(s, signals[SIG_AUTOPLUG_SORT], 0, parsepad, caps, factories, &sorted);
        if (sorted != null) {
            c.g_value_array_free(factories);
            factories = sorted;
        }
        if (is_pc) {
            const pelem = firstElem(chain).?;
            var filter = c.gst_caps_new_empty();
            var i: c.guint = 0;
            while (i < factories.*.n_values) : (i += 1) {
                const f: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(factories, i))));
                if (c.gst_element_get_factory(src) == f or c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_PARSER) != 0) continue;
                var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
                while (tl) |n| : (tl = n.next) {
                    const st: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
                    if (st.direction != c.GST_PAD_SINK or st.presence != c.GST_PAD_ALWAYS) continue;
                    const tcaps = c.gst_static_pad_template_get_caps(st);
                    filter = c.gst_caps_merge(filter, c.gst_caps_intersect_full(tcaps, caps, c.GST_CAPS_INTERSECT_FIRST));
                    c.gst_caps_unref(tcaps);
                }
            }
            filter = c.gst_caps_merge(filter, c.gst_caps_ref(caps));
            pelem.capsfilter = c.gst_element_factory_make("capsfilter", null);
            c.g_object_set(gobj(pelem.capsfilter), "caps", filter, N);
            c.gst_caps_unref(filter);
            _ = c.gst_element_set_state(pelem.capsfilter, c.GST_STATE_PAUSED);
            _ = c.gst_bin_add(binOf(s), ref(pelem.capsfilter.?));
            setTarget(parsepad.?, null);
            const sp = c.gst_element_get_static_pad(pelem.capsfilter, "sink");
            _ = c.gst_pad_link_full(pad, sp, c.GST_PAD_LINK_CHECK_NOTHING);
            c.gst_object_unref(sp);
            const fp = c.gst_element_get_static_pad(pelem.capsfilter, "src");
            setTarget(parsepad.?, fp);
            pad = fp;
            c.gst_caps_unref(caps);
            caps = c.gst_pad_get_current_caps(pad);
            if (caps == null) {
                c.gst_object_unref(parsepad);
                parsepad = null;
                c.g_value_array_free(factories);
                factories = null;
                break :blk .delay;
            }
        }
        const ok = connectPad(s, src, parsepad.?, pad, caps, factories, chain, &details);
        if (is_pc) c.gst_object_unref(pad);
        c.g_value_array_free(factories);
        factories = null;
        if (!ok) {
            if (details == null) {
                const cf = c.gst_pb_utils_get_caps_description_flags(caps);
                if (cf != 0 and (cf & c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_CONTAINER) == 0) break :blk .expose;
            }
            break :blk .unknown;
        }
        c.gst_object_unref(parsepad);
        c.gst_caps_unref(caps);
        break :blk .done;
    };
    switch (next) {
        .done => {},
        .expose => {
            exposePad(s, src, parsepad.?, pad, caps, chain);
            c.gst_object_unref(parsepad);
            c.gst_caps_unref(caps);
        },
        .unknown => {
            if (parsepad) |p| c.gst_object_unref(p);
            chain.deadend_details = details;
            chain.deadend = true;
            chain.drained = true;
            chain.endcaps = caps;
            _ = c.gst_object_replace(@ptrCast(&chain.current_pad), null);
            _ = c.gst_element_post_message(elem(s), c.gst_missing_decoder_message_new(elem(s), caps));
            c.g_signal_emit(s, signals[SIG_UNKNOWN_TYPE], 0, pad, caps);
            exposeIfComplete(s);
            if (src == s.typefind and (caps == null or c.gst_caps_is_empty(caps) != 0))
                cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_TYPE_NOT_FOUND, c.g_strdup(tr("Could not determine type of stream")), null, FILE, "analyze_new_pad", 1580);
        },
        .delay => {
            delayPad(chain, pad);
            if (is_pc) c.gst_object_unref(pad);
            if (caps != null) c.gst_caps_unref(caps);
        },
    }
}

fn addFilter(s: *Self, e: ?*c.GstElement) void {
    cm.lock(s);
    s.filtered = c.g_list_prepend(s.filtered, e);
    cm.unlock(s);
}

fn removeFilter(s: *Self, e: ?*c.GstElement, err: ?*[*c]c.GstMessage) void {
    cm.lock(s);
    defer cm.unlock(s);
    s.filtered = c.g_list_remove(s.filtered, e);
    if (err) |x| x.* = null;
    var l = s.filtered_errors;
    while (l != null) {
        const msg: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        if (msg.*.src == cm.obj(e)) {
            if (err) |x| _ = c.gst_message_replace(x, msg);
            c.gst_message_unref(msg);
            s.filtered_errors = c.g_list_delete_link(s.filtered_errors, l);
            l = s.filtered_errors;
        } else l = l.*.next;
    }
}

fn sendSticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *struct { ok: bool, peer: ?*c.GstPad } = @ptrCast(@alignCast(data));
    if (c.gst_pad_send_event(d.peer, c.gst_event_ref(ev.*)) == 0) d.ok = false;
    return @intFromBool(d.ok);
}

fn sendStickyEvents(pad: ?*c.GstPad) void {
    var d: struct { ok: bool, peer: ?*c.GstPad } = .{ .ok = true, .peer = c.gst_pad_get_peer(pad) };
    _ = c.gst_pad_sticky_events_foreach(pad, sendSticky, &d);
    c.gst_object_unref(d.peer);
}

fn errorText(msg: [*c]c.GstMessage) [*c]u8 {
    var err: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(msg, &err, &dbg);
    const m = c.gst_error_get_message(err.*.domain, err.*.code);
    const full = if (dbg != null) c.g_strdup_printf("%s\n%s\n%s", m, err.*.message, dbg) else c.g_strdup_printf("%s\n%s", m, err.*.message);
    c.g_free(m);
    c.g_free(dbg);
    c.g_clear_error(&err);
    return full;
}

fn isSimpleDemuxer(f: ?*c.GstElementFactory) bool {
    if (!hasText(klassOf(f), "Demuxer")) return false;
    var always: c.gint = 0;
    var l: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
    while (l) |n| : (l = n.next) {
        const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
        if (t.direction != c.GST_PAD_SRC) continue;
        if (t.presence == c.GST_PAD_ALWAYS) {
            if (always >= 0) always += 1;
        } else always = -1;
    }
    return always == 1;
}

fn setSpeed(s: *Self, e: ?*c.GstElement) void {
    const spec = c.g_object_class_find_property(@ptrCast(@alignCast(gobj(e).g_type_instance.g_class)), "connection-speed") orelse return;
    const speed = s.speed / 1000;
    const t = spec.*.g_type_instance.g_class.*.g_type;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_UINT64);
    defer c.g_value_unset(&v);
    if (t == c.G_TYPE_PARAM_UINT()) {
        const p: *c.GParamSpecUInt = @ptrCast(@alignCast(spec));
        c.g_value_set_uint64(&v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT()) {
        const p: *c.GParamSpecInt = @ptrCast(@alignCast(spec));
        const lo: u64 = @bitCast(@as(i64, p.minimum));
        const hi: u64 = @bitCast(@as(i64, p.maximum));
        c.g_value_set_uint64(&v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else if (t == c.G_TYPE_PARAM_UINT64()) {
        const p: *c.GParamSpecUInt64 = @ptrCast(@alignCast(spec));
        c.g_value_set_uint64(&v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT64()) {
        const p: *c.GParamSpecInt64 = @ptrCast(@alignCast(spec));
        const lo: u64 = @bitCast(p.minimum);
        const hi: u64 = @bitCast(p.maximum);
        c.g_value_set_uint64(&v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else return;
    c.g_object_set_property(gobj(e), "connection-speed", &v);
}

fn analyzeList(s: *Self, e: ?*c.GstElement, list: [*c]c.GList, chain: *Chain) void {
    var l = list;
    while (l != null) : (l = l.*.next) {
        const op: ?*c.GstPad = @ptrCast(@alignCast(l.*.data));
        const oc = padCaps(op);
        analyzeNewPad(s, e, op, oc, chain);
        if (oc != null) c.gst_caps_unref(oc);
        c.gst_object_unref(op);
    }
    c.g_list_free(list);
}

fn unwindTo(s: *Self, chain: *Chain, element: ?*c.GstElement) void {
    chainLock(chain);
    defer chainUnlock(chain);
    while (true) {
        const d = firstElem(chain).?;
        const tmp = d.element;
        if (d.added_id != 0) c.g_signal_handler_disconnect(tmp, d.added_id);
        if (d.removed_id != 0) c.g_signal_handler_disconnect(tmp, d.removed_id);
        if (d.nmp_id != 0) c.g_signal_handler_disconnect(tmp, d.nmp_id);
        var l = chain.pending_pads;
        while (l != null) {
            const pp: *Pending = @ptrCast(@alignCast(l.*.data));
            if (cm.padParent(pp.pad) != @as(?*anyopaque, @ptrCast(tmp))) {
                l = l.*.next;
                continue;
            }
            freePending(pp);
            const n = l.*.next;
            chain.pending_pads = c.g_list_delete_link(chain.pending_pads, l);
            l = n;
        }
        if (d.capsfilter) |cf| {
            _ = c.gst_bin_remove(binOf(s), cf);
            _ = c.gst_element_set_state(cf, c.GST_STATE_NULL);
            c.gst_object_unref(cf);
        }
        _ = c.gst_bin_remove(binOf(s), tmp);
        _ = c.gst_element_set_state(tmp, c.GST_STATE_NULL);
        c.gst_object_unref(tmp);
        A.destroy(d);
        chain.elements = c.g_list_delete_link(chain.elements, chain.elements);
        if (tmp == element) break;
    }
}

fn connectPad(s: *Self, src: ?*c.GstElement, parsepad: *PPad, pad: ?*c.GstPad, caps: [*c]c.GstCaps, factories: [*c]c.GValueArray, chain: *Chain, deadend: *[*c]u8) bool {
    if (!cm.that(factories != null, "connect_pad", "factories != NULL")) return false;
    if (!cm.that(factories.*.n_values > 0, "connect_pad", "factories->n_values > 0")) return false;
    var res = false;
    var segment_format: c.GstFormat = c.GST_FORMAT_TIME;
    if (c.gst_pb_utils_get_caps_description_flags(caps) == c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_SUBTITLE) {
        segment_format = c.GST_FORMAT_UNDEFINED;
        if (c.gst_pad_get_sticky_event(pad, c.GST_EVENT_SEGMENT, 0)) |se| {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(se, &seg);
            if (seg != null) segment_format = seg.*.format;
            c.gst_event_unref(se);
        }
        if (segment_format == c.GST_FORMAT_UNDEFINED) {
            const q = c.gst_query_new_segment(c.GST_FORMAT_TIME);
            if (c.gst_pad_query(pad, q) != 0) c.gst_query_parse_segment(q, null, &segment_format, null, null);
            c.gst_query_unref(q);
        }
    }
    const details = c.g_string_new("");
    defer deadend.* = c.g_string_free(details, @intFromBool(details.*.len == 0 or res));
    while (factories.*.n_values > 0) {
        setTarget(parsepad, pad);
        const factory: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(factories, 0))));
        _ = c.g_object_ref(factory);
        defer c.g_object_unref(factory);
        _ = c.g_value_array_remove(factories, 0);
        if (c.gst_caps_is_fixed(caps) != 0) {
            var skip = false;
            var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(factory);
            while (tl) |n| : (tl = n.next) {
                const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
                if (t.direction != c.GST_PAD_SINK) continue;
                const tc = c.gst_static_caps_get(&t.static_caps);
                const sub = c.gst_caps_is_subset(caps, tc) != 0;
                c.gst_caps_unref(tc);
                if (!sub) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }
        const is_pc = hasText(klassOf(factory), "Parser");
        const is_simple = isSimpleDemuxer(factory);
        if (is_pc) {
            var skip = false;
            chainLock(chain);
            var l = chain.elements;
            while (l != null) : (l = l.*.next) {
                const pe: *Elem = @ptrCast(@alignCast(l.*.data));
                if (c.gst_element_get_factory(pe.element) == factory) {
                    skip = true;
                    break;
                }
            }
            if (!skip) if (chain.parent) |g| if (g.parent) |pc| if (firstElem(pc)) |pe| {
                if (c.gst_element_get_factory(pe.element) == factory) skip = true;
            };
            chainUnlock(chain);
            if (skip) continue;
        }
        var ret: c.gint = flags.SELECT_TRY;
        if (c.gst_element_factory_list_is_type(factory, c.GST_ELEMENT_FACTORY_TYPE_DECODER) != 0 and segment_format == c.GST_FORMAT_TIME) {
            ret = flags.SELECT_EXPOSE;
        } else c.g_signal_emit(s, signals[SIG_AUTOPLUG_SELECT], 0, parsepad, caps, factory, &ret);
        if (ret == flags.SELECT_EXPOSE) {
            exposePad(s, src, parsepad, pad, caps, chain);
            res = true;
            return res;
        }
        if (ret == flags.SELECT_SKIP) continue;
        setTarget(parsepad, null);
        const fname = cm.obj(factory).name;
        const element = c.gst_element_factory_create(factory, null) orelse {
            c.g_string_append_printf(details, "Could not create an element from %s\n", fname);
            continue;
        };
        addFilter(s, element);
        _ = c.gst_element_set_locked_state(element, 1);
        const ename = cm.obj(element).name;
        if (c.gst_bin_add(binOf(s), element) == 0) {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Couldn't add %s to the bin\n", ename);
            c.gst_object_unref(element);
            continue;
        }
        cm.lock(element);
        const sinkpad: ?*c.GstPad = if (element.*.sinkpads != null) @ptrCast(@alignCast(c.gst_object_ref(element.*.sinkpads.*.data))) else null;
        cm.unlock(element);
        if (sinkpad == null) {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Element %s doesn't have a sink pad", cm.obj(element).name);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        if (c.gst_pad_link_full(pad, sinkpad, c.GST_PAD_LINK_CHECK_NOTHING) != c.GST_PAD_LINK_OK) {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Link failed on pad %s:%s", cm.padParentName(sinkpad), cm.padName(sinkpad));
            c.gst_object_unref(sinkpad);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        if (c.gst_element_set_state(element, c.GST_STATE_READY) == c.GST_STATE_CHANGE_FAILURE) {
            var msg: [*c]c.GstMessage = null;
            removeFilter(s, element, &msg);
            if (msg != null) {
                const es = errorText(msg);
                c.g_string_append_printf(details, "Couldn't set %s to READY:\n%s", cm.obj(element).name, es);
                c.gst_message_unref(msg);
                c.g_free(es);
            } else c.g_string_append_printf(details, "Couldn't set %s to READY", cm.obj(element).name);
            c.gst_object_unref(sinkpad);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        if (c.gst_pad_query_accept_caps(sinkpad, caps) == 0) {
            var msg: [*c]c.GstMessage = null;
            removeFilter(s, element, &msg);
            if (msg != null) {
                const es = errorText(msg);
                c.g_string_append_printf(details, "Element %s does not accept caps:\n%s", cm.obj(element).name, es);
                c.gst_message_unref(msg);
                c.g_free(es);
            } else c.g_string_append_printf(details, "Element %s does not accept caps", cm.obj(element).name);
            _ = c.gst_element_set_state(element, c.GST_STATE_NULL);
            c.gst_object_unref(sinkpad);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        c.gst_object_unref(sinkpad);
        chainLock(chain);
        const pelem = A.create(Elem) catch @panic("oom");
        pelem.* = .{ .element = ref(element) };
        chain.elements = c.g_list_prepend(chain.elements, pelem);
        chain.demuxer = isDemuxer(element);
        chain.parsed = chain.parsed or is_pc;
        chainUnlock(chain);
        if (chain.demuxer) setSpeed(s, element);
        var subtitle = false;
        if (c.g_object_class_find_property(@ptrCast(@alignCast(gobj(element).g_type_instance.g_class)), "subtitle-encoding")) |spec| {
            if (spec.*.value_type == c.G_TYPE_STRING) {
                c.g_mutex_lock(&s.subtitle_lock);
                c.g_object_set(gobj(element), "subtitle-encoding", s.encoding, N);
                c.g_mutex_unlock(&s.subtitle_lock);
                subtitle = true;
            }
        }
        var to_connect = connectElement(s, pelem, chain);
        if ((is_simple or is_pc) and to_connect != null) {
            analyzeList(s, pelem.element, to_connect, chain);
            to_connect = null;
        }
        cm.streamLock(sinkpad);
        if (c.gst_element_set_state(element, c.GST_STATE_PAUSED) == c.GST_STATE_CHANGE_FAILURE) {
            cm.streamUnlock(sinkpad);
            c.g_list_free_full(to_connect, c.gst_object_unref);
            var msg: [*c]c.GstMessage = null;
            removeFilter(s, element, &msg);
            if (msg != null) {
                const es = errorText(msg);
                c.g_string_append_printf(details, "Couldn't set %s to PAUSED:\n%s", cm.obj(element).name, es);
                c.gst_message_unref(msg);
                c.g_free(es);
            } else c.g_string_append_printf(details, "Couldn't set %s to PAUSED", cm.obj(element).name);
            unwindTo(s, chain, element);
            continue;
        }
        sendStickyEvents(pad);
        cm.streamUnlock(sinkpad);
        removeFilter(s, element, null);
        _ = c.gst_element_set_locked_state(element, 0);
        if (subtitle) {
            c.g_mutex_lock(&s.subtitle_lock);
            s.subtitles = c.g_list_prepend(s.subtitles, element);
            c.g_mutex_unlock(&s.subtitle_lock);
        }
        if (to_connect != null) analyzeList(s, pelem.element, to_connect, chain);
        res = true;
        break;
    }
    return res;
}

fn padCaps(pad: ?*c.GstPad) [*c]c.GstCaps {
    const caps = c.gst_pad_get_current_caps(pad);
    return if (caps != null) caps else c.gst_pad_query_caps(pad, null);
}

fn connectElement(_: *Self, pelem: *Elem, chain: *Chain) [*c]c.GList {
    const e = pelem.element;
    var dynamic = false;
    var out: [*c]c.GList = null;
    var l = @as(*c.GstElementClass, @ptrCast(@alignCast(gobj(e).g_type_instance.g_class))).padtemplates;
    while (l != null) : (l = l.*.next) {
        const t: *c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t.direction != c.GST_PAD_SRC) continue;
        switch (t.presence) {
            c.GST_PAD_ALWAYS => {
                if (c.gst_element_get_static_pad(e, t.name_template)) |p| out = c.g_list_prepend(out, p);
            },
            c.GST_PAD_SOMETIMES => {
                if (c.gst_element_get_static_pad(e, t.name_template)) |p| {
                    out = c.g_list_prepend(out, p);
                } else dynamic = true;
            },
            else => {},
        }
    }
    if (dynamic) {
        pelem.added_id = c.g_signal_connect_data(e, "pad-added", @ptrCast(&padAdded), chain, null, 0);
        pelem.removed_id = c.g_signal_connect_data(e, "pad-removed", @ptrCast(&padRemoved), chain, null, 0);
        pelem.nmp_id = c.g_signal_connect_data(e, "no-more-pads", @ptrCast(&noMorePads), chain, null, 0);
    }
    return out;
}

fn exposePad(_: *Self, _: ?*c.GstElement, parsepad: *PPad, _: ?*c.GstPad, caps: [*c]c.GstCaps, chain: *Chain) void {
    activatePad(parsepad, chain);
    chain.endpad = ref(parsepad);
    chain.endcaps = if (caps != null) c.gst_caps_ref(caps) else null;
}

fn typeFound(tf: ?*c.GstElement, _: c.guint, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    if (c.gst_structure_has_name(c.gst_caps_get_structure(caps, 0), "text/plain") != 0) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_WRONG_TYPE, c.g_strdup(tr("This appears to be a text file")), c.g_strdup("ParseBin cannot parse plain text files"), FILE, "type_found", 2445);
        return;
    }
    if (s.have_type != 0 or s.chain != null) return;
    s.have_type = 1;
    const pad = c.gst_element_get_static_pad(tf, "src");
    const sink = c.gst_element_get_static_pad(tf, "sink");
    cm.streamLock(sink);
    const ch = newChain(s, null, pad, caps);
    s.chain = ch;
    analyzeNewPad(s, tf, pad, caps, ch);
    cm.streamUnlock(sink);
    c.gst_object_unref(sink);
    c.gst_object_unref(pad);
}

fn pendingEvent(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const pp: *Pending = @ptrCast(@alignCast(data));
    const ch = pp.chain;
    if (cm.eventType(info.*.data) == c.GST_EVENT_EOS) {
        ch.deadend = true;
        ch.drained = true;
        _ = c.gst_object_replace(@ptrCast(&ch.current_pad), null);
        exposeIfComplete(ch.bin);
    }
    return c.GST_PAD_PROBE_OK;
}

fn padAdded(e: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const ch: *Chain = @ptrCast(@alignCast(data));
    const s = ch.bin;
    const caps = padCaps(pad);
    analyzeNewPad(s, e, pad, caps, ch);
    if (caps != null) c.gst_caps_unref(caps);
    exposeIfComplete(s);
}

fn padRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const ch: *Chain = @ptrCast(@alignCast(data));
    chainLock(ch);
    defer chainUnlock(ch);
    var l = ch.pending_pads;
    while (l != null) : (l = l.*.next) {
        const pp: *Pending = @ptrCast(@alignCast(l.*.data));
        if (pp.pad == pad) {
            freePending(pp);
            ch.pending_pads = c.g_list_delete_link(ch.pending_pads, l);
            return;
        }
    }
}

fn noMorePads(e: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const ch: *Chain = @ptrCast(@alignCast(data));
    chainLock(ch);
    const first = firstElem(ch);
    if (first == null or first.?.element != e or !ch.demuxer) {
        chainUnlock(ch);
        return;
    }
    var group: ?*Group = null;
    if (ch.next_groups == null and ch.active_group != null) {
        group = ch.active_group;
    } else if (ch.next_groups != null) {
        var l = ch.next_groups;
        while (l != null) : (l = l.*.next) {
            group = @ptrCast(@alignCast(l.*.data));
            if (!group.?.no_more_pads) break;
        }
    }
    const g = group orelse {
        chainUnlock(ch);
        return;
    };
    g.no_more_pads = true;
    chainUnlock(ch);
    exposeIfComplete(ch.bin);
}

fn capsNotify(pad: ?*c.GstPad, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const ch: *Chain = @ptrCast(@alignCast(data));
    const e = elem(c.gst_object_get_parent(cm.obj(pad)));
    chainLock(ch);
    var l = ch.pending_pads;
    while (l != null) : (l = l.*.next) {
        const pp: *Pending = @ptrCast(@alignCast(l.*.data));
        if (pp.pad == pad) {
            freePending(pp);
            ch.pending_pads = c.g_list_delete_link(ch.pending_pads, l);
            break;
        }
    }
    chainUnlock(ch);
    padAdded(e, pad, ch);
    c.gst_object_unref(e);
}

fn isDemuxer(e: ?*c.GstElement) bool {
    if (!hasText(klassOf(c.gst_element_get_factory(e)), "Demux")) return false;
    var n: c.gint = 0;
    var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(gobj(e).g_type_instance.g_class)));
    while (l != null) : (l = l.*.next) {
        const t: *c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t.direction != c.GST_PAD_SRC) continue;
        switch (t.presence) {
            c.GST_PAD_ALWAYS, c.GST_PAD_SOMETIMES => n += if (c.strstr(t.name_template, "%") != null) 2 else 1,
            c.GST_PAD_REQUEST => n += 2,
            else => {},
        }
    }
    return n >= 2;
}

fn currentGroup(ch: *Chain) *Group {
    var group: ?*Group = null;
    if (ch.active_group == null) {
        group = newGroup(ch.bin, ch);
        ch.active_group = group;
    } else if (!ch.active_group.?.no_more_pads) {
        group = ch.active_group;
    } else {
        var l = ch.next_groups;
        while (l != null) : (l = l.*.next) {
            const g: *Group = @ptrCast(@alignCast(l.*.data));
            if (!g.no_more_pads) {
                group = g;
                break;
            }
        }
    }
    if (group == null) {
        group = newGroup(ch.bin, ch);
        ch.next_groups = c.g_list_append(ch.next_groups, group);
    }
    return group.?;
}

fn freeChainInternal(ch: *Chain, hide: bool) void {
    const s = ch.bin;
    var to_null: [*c]c.GList = null;
    chainLock(ch);
    if (ch.active_group) |g| {
        freeGroupInternal(g, hide);
        if (!hide) ch.active_group = null;
    }
    var l = ch.next_groups;
    while (l != null) : (l = l.*.next) {
        freeGroupInternal(@ptrCast(@alignCast(l.*.data)), hide);
        if (!hide) l.*.data = null;
    }
    if (!hide) {
        c.g_list_free(ch.next_groups);
        ch.next_groups = null;
        l = ch.old_groups;
        while (l != null) : (l = l.*.next) freeGroupInternal(@ptrCast(@alignCast(l.*.data)), false);
        c.g_list_free(ch.old_groups);
        ch.old_groups = null;
    }
    _ = c.gst_object_replace(@ptrCast(&ch.current_pad), null);
    l = ch.pending_pads;
    while (l != null) : (l = l.*.next) {
        freePending(@ptrCast(@alignCast(l.*.data)));
        l.*.data = null;
    }
    c.g_list_free(ch.pending_pads);
    ch.pending_pads = null;
    l = ch.elements;
    while (l != null) : (l = l.*.next) {
        const pe: *Elem = @ptrCast(@alignCast(l.*.data));
        const e = pe.element;
        if (pe.added_id != 0) c.g_signal_handler_disconnect(e, pe.added_id);
        pe.added_id = 0;
        if (pe.removed_id != 0) c.g_signal_handler_disconnect(e, pe.removed_id);
        pe.removed_id = 0;
        if (pe.nmp_id != 0) c.g_signal_handler_disconnect(e, pe.nmp_id);
        pe.nmp_id = 0;
        if (pe.capsfilter) |cf| {
            if (cm.obj(cf).parent == cm.obj(s)) _ = c.gst_bin_remove(binOf(s), cf);
            if (!hide) to_null = c.g_list_append(to_null, c.gst_object_ref(cf));
        }
        if (cm.obj(e).parent == cm.obj(s)) _ = c.gst_bin_remove(binOf(s), e);
        if (!hide) to_null = c.g_list_append(to_null, c.gst_object_ref(e));
        c.g_mutex_lock(&s.subtitle_lock);
        s.subtitles = c.g_list_remove(s.subtitles, e);
        c.g_mutex_unlock(&s.subtitle_lock);
        if (!hide) {
            if (pe.capsfilter) |cf| c.gst_object_unref(cf);
            pe.capsfilter = null;
            c.gst_object_unref(e);
            l.*.data = null;
            A.destroy(pe);
        }
    }
    if (!hide) {
        c.g_list_free(ch.elements);
        ch.elements = null;
    }
    if (ch.endpad) |ep| {
        if (ep.exposed != 0) {
            _ = c.gst_pad_push_event(padOf(ep), c.gst_event_new_eos());
            _ = c.gst_element_remove_pad(elem(s), padOf(ep));
        }
        setTarget(ep, null);
        ep.exposed = 0;
        if (!hide) {
            c.gst_object_unref(ep);
            ch.endpad = null;
        }
    }
    if (!hide) if (ch.current_pad) |cp| {
        c.gst_object_unref(cp);
        ch.current_pad = null;
    };
    if (ch.pad) |p| {
        c.gst_object_unref(p);
        ch.pad = null;
    }
    if (ch.start_caps != null) {
        c.gst_caps_unref(ch.start_caps);
        ch.start_caps = null;
    }
    if (ch.endcaps != null) {
        c.gst_caps_unref(ch.endcaps);
        ch.endcaps = null;
    }
    c.g_free(ch.deadend_details);
    ch.deadend_details = null;
    chainUnlock(ch);
    while (to_null != null) {
        const e: ?*c.GstElement = @ptrCast(@alignCast(to_null.*.data));
        to_null = c.g_list_delete_link(to_null, to_null);
        _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
        c.gst_object_unref(e);
    }
    if (!hide) {
        c.g_mutex_clear(&ch.lock);
        A.destroy(ch);
    }
}

fn freeChain(ch: *Chain) void {
    freeChainInternal(ch, false);
}

fn newChain(s: *Self, parent: ?*Group, pad: ?*c.GstPad, caps: [*c]c.GstCaps) *Chain {
    const ch = A.create(Chain) catch @panic("oom");
    ch.* = .{ .parent = parent, .bin = s };
    c.g_mutex_init(&ch.lock);
    ch.pad = ref(pad.?);
    if (caps != null) ch.start_caps = c.gst_caps_ref(caps);
    return ch;
}

fn freeGroupInternal(g: *Group, hide: bool) void {
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        freeChainInternal(@ptrCast(@alignCast(l.*.data)), hide);
        if (!hide) l.*.data = null;
    }
    if (!hide) {
        c.g_list_free(g.children);
        g.children = null;
        A.destroy(g);
    }
}

fn freeHidden(data: c.gpointer) callconv(.c) c.gpointer {
    var list: [*c]c.GList = @ptrCast(@alignCast(data));
    var l = list;
    while (l != null) : (l = l.*.next) freeGroupInternal(@ptrCast(@alignCast(l.*.data)), false);
    c.g_list_free(list);
    list = null;
    return null;
}

fn startFreeHidden(ch: *Chain) void {
    const s = ch.bin;
    const old = ch.old_groups;
    if (old == null) return;
    c.g_mutex_lock(&s.cleanup_lock);
    defer c.g_mutex_unlock(&s.cleanup_lock);
    if (s.cleanup_thread) |t| {
        _ = c.g_thread_join(t);
        s.cleanup_thread = null;
    }
    ch.old_groups = null;
    var err: [*c]c.GError = null;
    const t = c.g_thread_try_new("free-hidden-groups", freeHidden, old, &err);
    if (t == null or err != null) {
        c.g_clear_error(&err);
        ch.old_groups = old;
        return;
    }
    s.cleanup_thread = t;
}

fn newGroup(s: *Self, parent: ?*Chain) *Group {
    const g = A.create(Group) catch @panic("oom");
    g.* = .{ .bin = s, .parent = parent };
    return g;
}

fn groupIsComplete(g: *Group) bool {
    if (!g.no_more_pads) return false;
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        const ch: *Chain = @ptrCast(@alignCast(l.*.data));
        if (ch.endpad) |ep| if (ep.blocked != 0) return true;
        if (!chainIsComplete(ch)) return false;
    }
    return true;
}

fn chainIsComplete(ch: *Chain) bool {
    chainLock(ch);
    defer chainUnlock(ch);
    if (ch.bin.shutdown != 0) return false;
    if (ch.deadend) return true;
    if (ch.endpad) |ep| if (ep.blocked != 0 or ep.exposed != 0) return true;
    if (ch.demuxer) if (ch.active_group) |g| if (groupIsComplete(g)) return true;
    return ch.parsed;
}

fn removeOldGroups(ch: *Chain) void {
    if (ch.active_group) |g| {
        var l = g.children;
        while (l != null) : (l = l.*.next) removeOldGroups(@ptrCast(@alignCast(l.*.data)));
    }
    if (ch.old_groups != null) {
        freeGroupInternal(@ptrCast(@alignCast(ch.old_groups.*.data)), true);
        startFreeHidden(ch);
    }
}

fn chainAcceptCaps(ch: *Chain, caps: [*c]c.GstCaps) bool {
    if (ch.elements == null) return true;
    const initial: *Elem = @ptrCast(@alignCast(c.g_list_last(ch.elements).*.data));
    if (c.gst_element_get_static_pad(initial.element, "sink")) |sink| {
        const r = c.gst_pad_query_accept_caps(sink, caps) != 0;
        c.gst_object_unref(sink);
        return r;
    }
    const e = initial.element.?;
    cm.lock(e);
    if (e.numsinkpads == 0) {
        cm.unlock(e);
        return false;
    }
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.gst_object_ref(e.sinkpads)));
    cm.unlock(e);
    const r = c.gst_pad_query_accept_caps(pad, caps) != 0;
    c.gst_object_unref(pad);
    return r;
}

fn drainGroup(g: *Group, pad: ?*PPad, last: *bool, drained: *bool, switched: *bool) bool {
    var handled = false;
    if (!g.drained) {
        g.drained = true;
        var l = g.children;
        while (l != null) : (l = l.*.next) {
            var sub = false;
            handled = drainChains(@ptrCast(@alignCast(l.*.data)), pad, last, &sub, switched) or handled;
            if (!sub) g.drained = false;
        }
    }
    drained.* = g.drained;
    return handled;
}

fn drainChains(ch: *Chain, pad: ?*PPad, last: *bool, drained: *bool, switched: *bool) bool {
    var handled = false;
    chainLock(ch);
    defer {
        chainUnlock(ch);
        drained.* = ch.drained;
    }
    if (ch.drained) return handled;
    if (ch.endpad) |ep| {
        if (pad != null and @as(*anyopaque, ch) == pad.?.chain) {
            pad.?.drained = 1;
            handled = true;
        }
        ch.drained = ep.drained != 0;
        return handled;
    }
    if (ch.next_groups != null) last.* = false;
    if (ch.active_group) |g| {
        var sub = false;
        handled = drainGroup(g, pad, last, &sub, switched);
        if ((handled or pad == null) and sub and !switched.*) {
            if (ch.next_groups != null) {
                ch.old_groups = c.g_list_prepend(ch.old_groups, g);
                ch.active_group = @ptrCast(@alignCast(ch.next_groups.*.data));
                ch.next_groups = c.g_list_delete_link(ch.next_groups, ch.next_groups);
                switched.* = true;
                ch.drained = false;
            } else ch.drained = true;
        } else if (sub and ch.next_groups == null) drained.* = true;
    }
    return handled;
}

fn handleEos(p: *PPad) bool {
    var last = true;
    var switched = false;
    var drained = false;
    const s = chainOf(p).bin;
    exposeLock(s);
    if (rootChain(s)) |root| {
        _ = drainChains(root, p, &last, &drained, &switched);
        if (switched and chainIsComplete(root)) _ = expose(s);
        if (drained) c.g_signal_emit(s, signals[SIG_DRAINED], 0);
    }
    exposeUnlock(s);
    return last;
}

fn rank(name: [*c]const u8, caps_any: bool, caps_empty: bool, sized: bool) c.gint {
    if (!sized) {
        _ = caps_any;
        return if (caps_empty) 7 else 0;
    }
    const n = name;
    if (c.g_strrstr(n, "video/x-raw") != null) return 0;
    if (c.g_strrstr(n, "video/") != null) return 1;
    if (c.g_strrstr(n, "image/") != null) return 2;
    if (c.g_strrstr(n, "audio/x-raw") != null) return 3;
    if (c.g_strrstr(n, "audio/") != null) return 4;
    return 5;
}

fn sortEndPads(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const pa: ?*c.GstPad = @ptrCast(@alignCast(@constCast(a)));
    const pb: ?*c.GstPad = @ptrCast(@alignCast(@constCast(b)));
    const ca = padCaps(pa);
    const cb = padCaps(pb);
    var va: c.gint = 0;
    var vb: c.gint = 0;
    if (c.gst_caps_get_size(ca) == 0 or c.gst_caps_get_size(cb) == 0) {
        va = rank(null, c.gst_caps_is_any(ca) != 0, c.gst_caps_is_empty(ca) != 0, false);
        vb = rank(null, c.gst_caps_is_any(cb) != 0, c.gst_caps_is_empty(cb) != 0, false);
    } else {
        va = rank(c.gst_structure_get_name(c.gst_caps_get_structure(ca, 0)), false, false, true);
        vb = rank(c.gst_structure_get_name(c.gst_caps_get_structure(cb, 0)), false, false, true);
    }
    c.gst_caps_unref(ca);
    c.gst_caps_unref(cb);
    if (va != vb) return va - vb;
    const ia = c.gst_pad_get_stream_id(pa);
    const ib = c.gst_pad_get_stream_id(pb);
    defer c.g_free(ia);
    defer c.g_free(ib);
    if (ia == null) return 1;
    if (ib == null) return -1;
    return c.strcmp(ia, ib);
}

fn expose(s: *Self) bool {
    while (true) {
        var endpads: [*c]c.GList = null;
        var missing = false;
        var last = true;
        const details = c.g_string_new("");
        dynLock(s);
        if (s.shutdown != 0) {
            dynUnlock(s);
            _ = c.g_string_free(details, 1);
            return false;
        }
        dynUnlock(s);
        var uncollected = false;
        const root = rootChain(s).?;
        chainLock(root);
        if (!chainExpose(root, &endpads, &missing, details, &last, &uncollected)) {
            c.g_list_free_full(endpads, c.gst_object_unref);
            _ = c.g_string_free(details, 1);
            chainUnlock(root);
            return false;
        }
        chainUnlock(root);
        if (endpads == null) {
            if (missing) {
                if (details.*.len > 0) {
                    const d = c.g_string_free(details, 0);
                    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup_printf("no suitable plugins found:\n%s", d), FILE, "gst_parse_bin_expose", 3613);
                    c.g_free(d);
                } else {
                    _ = c.g_string_free(details, 1);
                    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no suitable plugins found"), FILE, "gst_parse_bin_expose", 3618);
                }
            } else {
                _ = c.g_string_free(details, 1);
                if (last) {
                    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup("all streams without buffers"), FILE, "gst_parse_bin_expose", 3629);
                } else {
                    var switched = false;
                    var drained = false;
                    _ = drainChains(root, null, &last, &drained, &switched);
                    cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup("all streams without buffers"), FILE, "gst_parse_bin_expose", 3637);
                    if (switched) {
                        if (chainIsComplete(root)) continue;
                        return false;
                    }
                }
            }
            return false;
        }
        var fallback: ?*c.GstStreamCollection = null;
        if (uncollected) {
            fallback = c.gst_stream_collection_new(null);
            buildFallback(root, fallback);
            _ = c.gst_element_post_message(elem(s), c.gst_message_new_stream_collection(cm.obj(s), fallback));
        }
        _ = c.g_string_free(details, 1);
        defer if (fallback) |f| c.gst_object_unref(f);
        var all = true;
        var l = endpads;
        while (l != null and all) : (l = l.*.next) all = ppad(l.*.data).exposed != 0;
        if (all) {
            c.g_list_free_full(endpads, c.gst_object_unref);
            return true;
        }
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = ppad(l.*.data);
            if (p.exposed != 0) setBlocked(p, true);
        }
        endpads = c.g_list_sort(endpads, sortEndPads);
        dynLock(s);
        if (s.shutdown != 0) {
            c.g_list_free_full(endpads, c.gst_object_unref);
            dynUnlock(s);
            return false;
        }
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = ppad(l.*.data);
            if (p.exposed != 0) continue;
            const name = c.g_strdup_printf("src_%u", s.nbpads);
            s.nbpads += 1;
            _ = c.gst_object_set_name(cm.obj(p), name);
            c.g_free(name);
            if (p.active_collection == null and fallback != null) {
                const ev = c.gst_event_new_stream_collection(fallback);
                _ = c.gst_pad_store_sticky_event(padOf(p), ev);
                c.gst_event_unref(ev);
            }
            p.exposed = 1;
            if (c.gst_element_add_pad(elem(s), padOf(p)) == 0) {
                c.g_log(null, c.G_LOG_LEVEL_WARNING, "error adding pad to ParseBin");
                p.exposed = 0;
            }
        }
        dynUnlock(s);
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = ppad(l.*.data);
            if (p.exposed != 0) setBlocked(p, false);
            c.gst_object_unref(p);
        }
        c.g_list_free(endpads);
        removeOldGroups(root);
        return true;
    }
}

fn chainExpose(ch: *Chain, endpads: *[*c]c.GList, missing: *bool, details: *c.GString, last: *bool, uncollected: *bool) bool {
    if (ch.deadend) {
        if (ch.endcaps != null) {
            if (ch.deadend_details != null) {
                _ = c.g_string_append(details, ch.deadend_details);
                _ = c.g_string_append_c(details, '\n');
            } else {
                const desc = c.gst_pb_utils_get_codec_description(ch.endcaps);
                const cs = c.gst_caps_to_string(ch.endcaps);
                c.g_string_append_printf(details, "Missing parser: %s (%s)\n", desc, cs);
                c.g_free(cs);
                c.g_free(desc);
            }
            missing.* = true;
        }
        return true;
    }
    if (ch.endpad == null and ch.parsed and ch.pending_pads != null) {
        const pp: *Pending = @ptrCast(@alignCast(ch.pending_pads.*.data));
        const ep = ref(pp.pad.?);
        const e = elem(c.gst_object_get_parent(cm.obj(ep)));
        ch.pending_pads = c.g_list_remove(ch.pending_pads, pp);
        freePending(pp);
        exposePad(ch.bin, e, ch.current_pad.?, ep, null, ch);
        c.gst_object_unref(ep);
        c.gst_object_unref(e);
    }
    if (ch.endpad) |p| {
        if (p.active_stream != null and p.active_collection == null and p.in_fallback == 0) uncollected.* = true;
        endpads.* = c.g_list_prepend(endpads.*, c.gst_object_ref(p));
        return true;
    }
    if (ch.next_groups != null) last.* = false;
    const g = ch.active_group orelse {
        const p = ch.current_pad orelse return false;
        if (p.active_stream != null and p.active_collection == null and p.in_fallback == 0) uncollected.* = true;
        return false;
    };
    var ret = false;
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        const child: *Chain = @ptrCast(@alignCast(l.*.data));
        chainLock(child);
        ret = chainExpose(child, endpads, missing, details, last, uncollected) or ret;
        chainUnlock(child);
    }
    return ret;
}

fn buildFallback(ch: *Chain, col: ?*c.GstStreamCollection) void {
    const g = ch.active_group;
    if (ch.endpad != null or (ch.current_pad != null and g == null)) {
        const p = ch.current_pad.?;
        if (p.active_stream != null and p.active_collection == null) {
            if (c.gst_stream_get_stream_type(p.active_stream) == c.GST_STREAM_TYPE_UNKNOWN) {
                const caps = padCaps(padOf(p));
                if (caps != null) {
                    const t = guessType(caps);
                    if (t != c.GST_STREAM_TYPE_UNKNOWN) {
                        c.gst_stream_set_stream_type(p.active_stream, t);
                        c.gst_stream_set_caps(p.active_stream, caps);
                    }
                    c.gst_caps_unref(caps);
                }
            }
            _ = c.gst_stream_collection_add_stream(col, @ptrCast(@alignCast(c.gst_object_ref(p.active_stream))));
            p.in_fallback = 1;
        }
        return;
    }
    const grp = g orelse return;
    var l = c.g_list_last(grp.children);
    while (l != null) : (l = l.*.prev) buildFallback(@ptrCast(@alignCast(l.*.data)), col);
}

fn sourceBlocked(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const p = ppad(data);
    if ((info.*.type & c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM) != 0) {
        const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
        if (!cm.eventSerialized(ev)) return c.GST_PAD_PROBE_PASS;
        if (cm.eventSticky(ev) and cm.eventType(ev) != c.GST_EVENT_EOS) {
            const peer = c.gst_pad_get_peer(pad);
            _ = c.gst_pad_send_event(peer, ev);
            c.gst_object_unref(peer);
            return c.GST_PAD_PROBE_HANDLED;
        }
    } else if ((info.*.type & c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM) != 0) {
        if (!cm.querySerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
        if (c.gst_pad_has_current_caps(pad) == 0) return c.GST_PAD_PROBE_PASS;
    }
    const s = chainOf(p).bin;
    p.blocked = 1;
    exposeLock(s);
    if (s.chain != null) _ = expose(s);
    exposeUnlock(s);
    return c.GST_PAD_PROBE_OK;
}

fn startsWith(s: [*c]const u8, p: []const u8) bool {
    return s != null and std.mem.startsWith(u8, std.mem.span(s), p);
}

fn guessType(caps: [*c]c.GstCaps) c.GstStreamType {
    if (c.gst_caps_get_size(caps) < 1) return c.GST_STREAM_TYPE_UNKNOWN;
    const st = c.gst_caps_get_structure(caps, 0);
    var name = c.gst_structure_get_name(st);
    if (c.gst_structure_has_field(st, "original-media-type") != 0) name = c.gst_structure_get_string(st, "original-media-type");
    if (startsWith(name, "video/") or startsWith(name, "image/")) return c.GST_STREAM_TYPE_VIDEO;
    if (startsWith(name, "audio/")) return c.GST_STREAM_TYPE_AUDIO;
    if (startsWith(name, "text/") or startsWith(name, "subpicture/") or startsWith(name, "subtitle/") or startsWith(name, "closedcaption/")) return c.GST_STREAM_TYPE_TEXT;
    if (startsWith(name, "meta/")) return c.GST_STREAM_TYPE_METADATA;
    return switch (c.gst_pb_utils_get_caps_description_flags(caps)) {
        c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_AUDIO => c.GST_STREAM_TYPE_AUDIO,
        c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_VIDEO => c.GST_STREAM_TYPE_VIDEO,
        c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_SUBTITLE => c.GST_STREAM_TYPE_TEXT,
        c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_METADATA => c.GST_STREAM_TYPE_METADATA,
        else => c.GST_STREAM_TYPE_UNKNOWN,
    };
}

fn updateCaps(p: *PPad, caps: [*c]c.GstCaps) void {
    if (caps == null or p.active_stream == null) return;
    if (c.gst_caps_is_fixed(caps) != 0) c.gst_stream_set_caps(p.active_stream, caps);
    if (c.gst_stream_get_stream_type(p.active_stream) == c.GST_STREAM_TYPE_UNKNOWN) {
        const t = guessType(caps);
        if (t != c.GST_STREAM_TYPE_UNKNOWN) c.gst_stream_set_stream_type(p.active_stream, t);
    }
}

fn updateTags(p: *PPad, tags: ?*c.GstTagList) void {
    if (tags != null and c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM and p.active_stream != null) c.gst_stream_set_tags(p.active_stream, tags);
}

fn streamStart(p: *PPad, ev_in: ?*c.GstEvent) ?*c.GstEvent {
    var ev = ev_in;
    var id: [*c]const u8 = null;
    var sflags: c.GstStreamFlags = 0;
    c.gst_event_parse_stream_start(ev, &id);
    c.gst_event_parse_stream_flags(ev, &sflags);
    var repeat = false;
    if (p.active_stream != null and c.g_str_equal(p.active_stream.?.stream_id, id) != 0) {
        repeat = true;
    } else {
        _ = c.gst_object_replace(@ptrCast(&p.active_collection), null);
        p.in_fallback = 0;
    }
    var stream: ?*c.GstStream = null;
    c.gst_event_parse_stream(ev, &stream);
    if (stream == null) {
        var caps = c.gst_pad_get_current_caps(padOf(p));
        if (caps == null) {
            const peer = c.gst_ghost_pad_get_target(ghost(p));
            caps = c.gst_pad_get_current_caps(peer);
            c.gst_object_unref(peer);
        }
        if (repeat) {
            stream = @ptrCast(@alignCast(c.gst_object_ref(p.active_stream)));
        } else {
            stream = c.gst_stream_new(id, null, c.GST_STREAM_TYPE_UNKNOWN, sflags);
            _ = c.gst_object_replace(@ptrCast(&p.active_stream), cm.obj(stream));
        }
        if (caps != null) {
            updateCaps(p, caps);
            c.gst_caps_unref(caps);
        }
        ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
        c.gst_event_set_stream(ev, stream);
    }
    c.gst_object_unref(stream);
    return ev;
}

fn updateCollection(p: *PPad, col: ?*c.GstStreamCollection) void {
    _ = c.gst_object_replace(@ptrCast(&p.active_collection), cm.obj(col));
    p.in_fallback = 0;
}

fn padEvent(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    const parent = c.gst_object_get_parent(cm.obj(pad));
    const p = ppad(parent);
    var forward = true;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            updateCaps(p, caps);
        },
        c.GST_EVENT_TAG => {
            var tags: ?*c.GstTagList = null;
            c.gst_event_parse_tag(ev, &tags);
            updateTags(p, tags);
        },
        c.GST_EVENT_STREAM_START => info.*.data = streamStart(p, ev),
        c.GST_EVENT_STREAM_COLLECTION => {
            var col: ?*c.GstStreamCollection = null;
            c.gst_event_parse_stream_collection(ev, &col);
            updateCollection(p, col);
            _ = c.gst_element_post_message(elem(p.bin), c.gst_message_new_stream_collection(cm.obj(p.bin), col));
            c.gst_object_unref(col);
        },
        c.GST_EVENT_EOS => forward = handleEos(p),
        else => {},
    }
    c.gst_object_unref(parent);
    return if (forward) c.GST_PAD_PROBE_OK else c.GST_PAD_PROBE_DROP;
}

fn setBlocked(p: *PPad, blocked: bool) void {
    const s = p.bin.?;
    dynLock(s);
    defer dynUnlock(s);
    const opad = c.gst_ghost_pad_get_target(ghost(p)) orelse return;
    defer c.gst_object_unref(opad);
    if (!blocked or s.shutdown == 0) {
        if (blocked) {
            if (p.block_id == 0) p.block_id = c.gst_pad_add_probe(opad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM, sourceBlocked, c.gst_object_ref(p), c.gst_object_unref);
        } else {
            if (p.block_id != 0) {
                c.gst_pad_remove_probe(opad, p.block_id);
                p.block_id = 0;
            }
            p.blocked = 0;
        }
    }
    if (blocked) {
        if (s.shutdown != 0) {
            _ = c.gst_pad_set_active(padOf(p), 0);
        } else {
            _ = c.gst_object_ref(p);
            s.blocked_pads = c.g_list_prepend(s.blocked_pads, p);
        }
    } else if (c.g_list_find(s.blocked_pads, p)) |l| {
        c.gst_object_unref(p);
        s.blocked_pads = c.g_list_delete_link(s.blocked_pads, l);
    }
}

fn activatePad(p: *PPad, ch: *Chain) void {
    p.chain = ch;
    _ = c.gst_pad_set_active(padOf(p), 1);
    setBlocked(p, true);
}

fn ppadQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const p = ppad(parent);
    const ch = chainOf(p);
    var ret: c.gboolean = 0;
    chainLock(ch);
    if (p.exposed == 0 and p.bin.?.shutdown == 0 and !ch.deadend and ch.elements != null) {
        const pe = firstElem(ch).?;
        c.g_signal_emit(p.bin, signals[SIG_AUTOPLUG_QUERY], 0, p, pe.element, q, &ret);
    }
    chainUnlock(ch);
    if (ret == 0) ret = c.gst_pad_query_default(pad, parent, q);
    return ret;
}

fn newPad(s: *Self, ch: *Chain) *PPad {
    const tmpl = c.gst_static_pad_template_get(&src_t);
    const p = ppad(c.g_object_new(padType(), "direction", @as(c.gint, c.GST_PAD_SRC), "template", tmpl, N));
    p.chain = ch;
    p.bin = s;
    c.gst_object_unref(tmpl);
    const internal: ?*c.GstPad = @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(p)))));
    c.gst_pad_set_query_function_full(internal, ppadQuery, null, null);
    _ = c.gst_pad_add_probe(internal, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, padEvent, p, null);
    c.gst_object_unref(internal);
    return p;
}

fn freePending(pp: *Pending) void {
    if (pp.probe != 0) c.gst_pad_remove_probe(pp.pad, pp.probe);
    if (pp.caps_id != 0) c.g_signal_handler_disconnect(pp.pad, pp.caps_id);
    c.gst_object_unref(pp.pad);
    A.destroy(pp);
}

fn unblockPads(s: *Self) void {
    var l = s.blocked_pads;
    while (l != null) : (l = l.*.next) {
        const p = ppad(l.*.data);
        const opad = c.gst_ghost_pad_get_target(ghost(p)) orelse continue;
        if (p.block_id != 0) {
            c.gst_pad_remove_probe(opad, p.block_id);
            p.block_id = 0;
        }
        p.blocked = 0;
        _ = c.gst_pad_set_active(padOf(p), 0);
        c.gst_object_unref(p);
        c.gst_object_unref(opad);
    }
    c.g_list_free(s.blocked_pads);
    s.blocked_pads = null;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (s.typefind == null) {
                _ = c.gst_element_post_message(e, c.gst_missing_element_message_new(e, "typefind"));
                cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no typefind!"), FILE, "gst_parse_bin_change_state", 4520);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            exposeLock(s);
            if (rootChain(s)) |root| {
                freeChain(root);
                s.chain = null;
            }
            exposeUnlock(s);
            dynLock(s);
            s.shutdown = 0;
            dynUnlock(s);
            s.have_type = 0;
            s.have_type_id = c.g_signal_connect_data(s.typefind, "have-type", @ptrCast(&typeFound), s, null, 0);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            if (s.have_type_id != 0) c.g_signal_handler_disconnect(s.typefind, s.have_type_id);
            s.have_type_id = 0;
            dynLock(s);
            s.shutdown = 1;
            unblockPads(s);
            dynUnlock(s);
        },
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return c.GST_STATE_CHANGE_FAILURE;
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            exposeLock(s);
            const root = rootChain(s);
            if (root) |r| {
                freeChainInternal(r, true);
                s.chain = null;
            }
            exposeUnlock(s);
            if (root) |r| freeChain(r);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            c.g_mutex_lock(&s.cleanup_lock);
            if (s.cleanup_thread) |th| {
                _ = c.g_thread_join(th);
                s.cleanup_thread = null;
            }
            c.g_mutex_unlock(&s.cleanup_lock);
        },
        else => {},
    }
    return ret;
}

fn handleMessage(b: [*c]c.GstBin, msg: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    var drop = false;
    if (msg.*.type == c.GST_MESSAGE_ERROR) {
        dynLock(s);
        drop = s.shutdown != 0;
        dynUnlock(s);
        if (!drop) {
            cm.lock(s);
            drop = c.g_list_find(s.filtered, msg.*.src) != null;
            if (drop) s.filtered_errors = c.g_list_prepend(s.filtered_errors, c.gst_message_ref(msg));
            cm.unlock(s);
        }
    }
    if (drop) c.gst_message_unref(msg) else parent_class.?.handle_message.?(b, msg);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SUBTITLE_ENCODING => {
            c.g_mutex_lock(&s.subtitle_lock);
            c.g_free(s.encoding);
            s.encoding = c.g_strdup(c.g_value_get_string(v));
            var l = s.subtitles;
            while (l != null) : (l = l.*.next) c.g_object_set(gobj(l.*.data), "subtitle-encoding", s.encoding, N);
            c.g_mutex_unlock(&s.subtitle_lock);
        },
        PROP_SINK_CAPS => c.g_object_set(gobj(s.typefind), "force-caps", c.g_value_get_boxed(v), N),
        PROP_EXPOSE_ALL_STREAMS => s.expose_all = c.g_value_get_boolean(v),
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            s.speed = c.g_value_get_uint64(v) *% 1000;
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1052),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SUBTITLE_ENCODING => {
            c.g_mutex_lock(&s.subtitle_lock);
            const e = c.g_strdup(s.encoding);
            c.g_mutex_unlock(&s.subtitle_lock);
            c.g_value_take_string(v, e);
        },
        PROP_SINK_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.g_object_get(gobj(s.typefind), "force-caps", &caps, N);
            c.g_value_take_boxed(v, caps);
        },
        PROP_EXPOSE_ALL_STREAMS => c.g_value_set_boolean(v, s.expose_all),
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            c.g_value_set_uint64(v, s.speed / 1000);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1080),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.factories != null) c.gst_plugin_feature_list_free(s.factories);
    s.factories = null;
    if (rootChain(s)) |r| freeChain(r);
    s.chain = null;
    c.g_free(s.encoding);
    s.encoding = null;
    c.g_list_free(s.subtitles);
    s.subtitles = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_mutex_clear(&s.expose_lock);
    c.g_mutex_clear(&s.dyn_lock);
    c.g_mutex_clear(&s.subtitle_lock);
    c.g_mutex_clear(&s.factories_lock);
    c.g_mutex_clear(&s.cleanup_lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const t = cm.typeOfClass(k);
    const pad_t = c.gst_pad_get_type();
    const caps_t = c.gst_caps_get_type();
    const va_t = c.g_value_array_get_type();
    signals[SIG_UNKNOWN_TYPE] = c.g_signal_new("unknown-type", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "unknown_type"), null, null, null, c.G_TYPE_NONE, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_CONTINUE] = c.g_signal_new("autoplug-continue", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_continue"), boolAccu, null, null, c.G_TYPE_BOOLEAN, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_FACTORIES] = c.g_signal_new("autoplug-factories", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_factories"), arrayAccu, null, null, va_t, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_SORT] = c.g_signal_new("autoplug-sort", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_sort"), arrayHasValueAccu, null, null, va_t, 3, pad_t, caps_t, va_t | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    signals[SIG_AUTOPLUG_SELECT] = c.g_signal_new("autoplug-select", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_select"), selectAccu, null, null, flags.selectType(), 3, pad_t, caps_t, c.gst_element_factory_get_type());
    signals[SIG_AUTOPLUG_QUERY] = c.g_signal_new("autoplug-query", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_query"), boolOrAccu, null, null, c.G_TYPE_BOOLEAN, 3, pad_t, c.gst_element_get_type(), c.gst_query_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    signals[SIG_DRAINED] = c.g_signal_new("drained", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "drained"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINK_CAPS, c.g_param_spec_boxed("sink-caps", "Sink Caps", "The caps of the input data. (NULL = use typefind element)", caps_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_EXPOSE_ALL_STREAMS, c.g_param_spec_boolean("expose-all-streams", "Expose All Streams", "Expose all streams, including those of unknown type or that don't match the 'caps' property", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.autoplug_continue = autoplugContinue;
    kc.autoplug_factories = autoplugFactories;
    kc.autoplug_sort = autoplugSort;
    kc.autoplug_select = autoplugSelect;
    kc.autoplug_query = autoplugQuery;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_set_static_metadata(ec, "Parse Bin", "Generic/Bin/Parser", "Parse and de-multiplex to elementary stream", "Jan Schmidt <jan@centricular.com>, Edward Hervey <edward@centricular.com>");
    ec.change_state = changeState;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    _ = c.g_type_class_ref(padType());
    _ = c._gst_debug_category_new("parsebin", 0, "parser bin");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.g_mutex_init(&s.factories_lock);
    s.typefind = c.gst_element_factory_make("typefind", "typefind");
    if (s.typefind == null) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "can't find typefind element, ParseBin will not work");
    } else {
        if (c.gst_bin_add(binOf(s), s.typefind) == 0) {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "Could not add typefind element, ParseBin will not work");
            c.gst_object_unref(s.typefind);
            s.typefind = null;
        }
        const pad = c.gst_element_get_static_pad(s.typefind, "sink");
        const tmpl = c.gst_static_pad_template_get(&sink_t);
        const gp = c.gst_ghost_pad_new_from_template("sink", pad, tmpl);
        c.gst_pad_set_query_function_full(gp, sinkQuery, null, null);
        _ = c.gst_pad_set_active(gp, 1);
        _ = c.gst_element_add_pad(elem(s), gp);
        c.gst_object_unref(tmpl);
        c.gst_object_unref(pad);
    }
    c.g_mutex_init(&s.expose_lock);
    s.chain = null;
    c.g_mutex_init(&s.dyn_lock);
    s.shutdown = 0;
    s.blocked_pads = null;
    c.g_mutex_init(&s.subtitle_lock);
    s.encoding = null;
    s.expose_all = 1;
    s.speed = 0;
    c.g_mutex_init(&s.cleanup_lock);
    s.cleanup_thread = null;
    cm.obj(s).flags |= c.GST_BIN_FLAG_STREAMS_AWARE;
}

fn padDispose(o: [*c]c.GObject) callconv(.c) void {
    const p = ppad(o);
    setTarget(p, null);
    _ = c.gst_object_replace(@ptrCast(&p.active_collection), null);
    _ = c.gst_object_replace(@ptrCast(&p.active_stream), null);
    pad_parent.?.dispose.?(o);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = padDispose;
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = ppad(inst);
    p.chain = null;
    p.blocked = 0;
    p.exposed = 0;
    p.drained = 0;
    _ = c.gst_object_ref_sink(p);
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_ghost_pad_get_type(), c.g_intern_static_string("GstParsePad"), @sizeOf(GhostClass), padClassInit, @sizeOf(PPad), padInit, 0);
        }
    }.f);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstParseBin", Class, Self, classInit, init);
        }
    }.f);
}
