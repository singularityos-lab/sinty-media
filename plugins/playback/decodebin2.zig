const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const utils = @import("utils.zig");

const FILE = "../gst/playback/gstdecodebin2.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const SECOND: u64 = 1000000000;

const PRE_BYTES: c.guint = 8 * 1024 * 1024;
const PRE_BUFFERS: c.guint = 0;
const PRE_TIME_UNSEEKABLE: u64 = 10 * SECOND;
const PRE_TIME_SEEKABLE: u64 = 0;
const PLAY_BYTES: c.guint = 8 * 1024 * 1024;
const PLAY_BUFFERS: c.guint = 5;
const PLAY_TIME: u64 = 0;

const PROP_CAPS = 1;
const PROP_SUBTITLE_ENCODING = 2;
const PROP_SINK_CAPS = 3;
const PROP_USE_BUFFERING = 4;
const PROP_FORCE_SW_DECODERS = 5;
const PROP_LOW_PERCENT = 6;
const PROP_HIGH_PERCENT = 7;
const PROP_MAX_SIZE_BYTES = 8;
const PROP_MAX_SIZE_BUFFERS = 9;
const PROP_MAX_SIZE_TIME = 10;
const PROP_POST_STREAM_TOPOLOGY = 11;
const PROP_EXPOSE_ALL_STREAMS = 12;
const PROP_CONNECTION_SPEED = 13;

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

const DemuxPad = struct {
    weak: c.GWeakRef = undefined,
    event_probe: c.gulong = 0,
    query_probe: c.gulong = 0,
};

const Group = struct {
    bin: *Self,
    parent: ?*Chain,
    mq: ?*c.GstElement = null,
    overrun_id: c.gulong = 0,
    overrun: bool = false,
    no_more_pads: bool = false,
    drained: bool = false,
    children: [*c]c.GList = null,
    demux_pads: [*c]c.GList = null,
    reqpads: [*c]c.GList = null,
};

const Chain = struct {
    parent: ?*Group,
    bin: *Self,
    refs: c.gint = 1,
    lock: c.GMutex = undefined,
    pad: ?*c.GstPad = null,
    probe: c.gulong = 0,
    drained: bool = false,
    demuxer: bool = false,
    adaptive: bool = false,
    seekable: bool = false,
    elements: [*c]c.GList = null,
    active_group: ?*Group = null,
    next_groups: [*c]c.GList = null,
    pending_pads: [*c]c.GList = null,
    current_pad: ?*DPad = null,
    endpad: ?*DPad = null,
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

pub const DPad = extern struct {
    parent: Ghost,
    bin: ?*Self,
    chain: ?*anyopaque,
    blocked: c.gboolean,
    exposed: c.gboolean,
    drained: c.gboolean,
    block_id: c.gulong,
};

const State = struct {
    caps: [*c]c.GstCaps = null,
    encoding: [*c]u8 = null,
    use_buffering: bool = false,
    force_sw: bool = false,
    low_percent: c.gint = 10,
    high_percent: c.gint = 99,
    max_bytes: c.guint = 0,
    max_buffers: c.guint = 0,
    max_time: u64 = 0,
    post_topology: bool = false,
    speed: u64 = 0,
    typefind: ?*c.GstElement = null,
    expose_lock: c.GMutex = undefined,
    chain: ?*Chain = null,
    nbpads: c.guint = 0,
    factories_lock: c.GMutex = undefined,
    cookie: u32 = 0,
    factories: [*c]c.GList = null,
    subtitle_lock: c.GMutex = undefined,
    subtitles: [*c]c.GList = null,
    have_type: bool = false,
    have_type_id: c.gulong = 0,
    async_pending: bool = false,
    dyn_lock: c.GMutex = undefined,
    shutdown: bool = false,
    blocked_pads: [*c]c.GList = null,
    expose_all: bool = true,
    filtered: [*c]c.GList = null,
    filtered_errors: [*c]c.GList = null,
    buffering: [*c]c.GList = null,
    buffering_lock: c.GMutex = undefined,
    buffering_post_lock: c.GMutex = undefined,
    cleanup_lock: c.GMutex = undefined,
    cleanup_thread: ?*c.GThread = null,
    cleanup_groups: [*c]c.GList = null,
};

pub const Self = extern struct {
    parent: c.GstBin,
    st: ?*State,
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

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn st(p: anytype) *State {
    return me(p).st.?;
}

fn dpad(p: anytype) *DPad {
    return @ptrCast(@alignCast(p));
}

fn chainOf(p: *DPad) *Chain {
    return @ptrCast(@alignCast(p.chain.?));
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
    c.g_mutex_lock(&st(s).expose_lock);
}

fn exposeUnlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).expose_lock);
}

fn dynLock(s: *Self) void {
    c.g_mutex_lock(&st(s).dyn_lock);
}

fn dynUnlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).dyn_lock);
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

fn classOf(e: anytype) *c.GObjectClass {
    return @ptrCast(@alignCast(gobj(e).g_type_instance.g_class));
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
    const t = st(s);
    const cookie = c.gst_registry_get_feature_list_cookie(c.gst_registry_get());
    if (t.factories != null and t.cookie == cookie) return;
    if (t.factories != null) c.gst_plugin_feature_list_free(t.factories);
    const all = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODABLE, c.GST_RANK_MARGINAL);
    if (t.force_sw) {
        t.factories = null;
        var l = all;
        while (l != null) : (l = l.*.next) {
            const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
            if (c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_HARDWARE) == 0) {
                t.factories = c.g_list_prepend(t.factories, f);
            } else c.gst_object_unref(f);
        }
        c.g_list_free(all);
    } else t.factories = all;
    t.factories = c.g_list_sort(t.factories, utils.compareFactories);
    t.cookie = cookie;
}

fn autoplugContinue(_: ?*c.GstElement, _: ?*c.GstPad, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return 1;
}

fn autoplugFactories(e: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GValueArray {
    const t = st(e);
    c.g_mutex_lock(&t.factories_lock);
    updateFactories(me(e));
    const list = c.gst_element_factory_list_filter(t.factories, caps, c.GST_PAD_SINK, c.gst_caps_is_fixed(caps));
    c.g_mutex_unlock(&t.factories_lock);
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

fn copySticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_store_sticky_event(padOf(data), ev.*);
    return 1;
}

fn setTarget(p: *DPad, target: ?*c.GstPad) void {
    _ = c.gst_ghost_pad_set_target(ghost(p), target);
    if (target == null) {
        _ = c.gst_pad_sticky_events_foreach(padOf(p), clearSticky, null);
    } else _ = c.gst_pad_sticky_events_foreach(target, copySticky, p);
}

fn exposeIfComplete(s: *Self) void {
    exposeLock(s);
    if (st(s).chain) |root| if (chainIsComplete(root)) {
        _ = expose(s);
    };
    exposeUnlock(s);
}

fn finalCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    cm.lock(s);
    defer cm.unlock(s);
    return c.gst_caps_is_subset(caps, st(s).caps) != 0;
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

fn rawSubset(caps: [*c]c.GstCaps) bool {
    const raw = utils.rawCaps();
    defer c.gst_caps_unref(raw);
    return c.gst_caps_is_subset(caps, raw) != 0;
}

fn decoderWouldDiscard(s: *Self, p: *DPad, factories: [*c]c.GValueArray) bool {
    var dontuse = false;
    var finals = false;
    var i: c.guint = 0;
    while (i < factories.*.n_values and !dontuse) : (i += 1) {
        const f: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(factories, i))));
        if (!hasText(klassOf(f), "Decoder")) continue;
        var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
        while (tl) |n| : (tl = n.next) {
            if (dontuse) break;
            const t: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
            if (t.direction != c.GST_PAD_SRC) continue;
            const tcaps = c.gst_static_pad_template_get_caps(t);
            var go: c.gboolean = 1;
            c.g_signal_emit(s, signals[SIG_AUTOPLUG_CONTINUE], 0, p, tcaps, &go);
            if (finalCaps(s, tcaps)) {
                finals = true;
            } else if (go != 0 and !finals) dontuse = true;
            c.gst_caps_unref(tcaps);
        }
    }
    return dontuse;
}

fn analyzeNewPad(s: *Self, src: ?*c.GstElement, pad_in: ?*c.GstPad, caps_in: [*c]c.GstCaps, chain_in: *Chain, new_chain: ?**Chain) bool {
    const t = st(s);
    var chain = chain_in;
    var pad = pad_in;
    if (new_chain) |x| x.* = chain;
    if (firstElem(chain)) |first| {
        if (src != first.element and src != first.capsfilter) return false;
    }
    if (chain.endpad != null) return false;
    if (chain.demuxer) {
        const old = chain;
        const demux = firstElem(chain);
        if (chain.current_pad) |p| c.gst_object_unref(p);
        chain.current_pad = null;
        chainLock(old);
        const group = currentGroup(chain);
        if (group) |g| if (c.g_list_find(g.children, chain) == null) {
            chain = newChain(s, g, pad);
            new_chain.?.* = chain;
            g.children = c.g_list_append(g.children, chain);
        };
        chainUnlock(old);
        const g = group orelse return false;
        if (demux == null or demux.?.nmp_id == 0) g.no_more_pads = true;
    }
    var caps = caps_in;
    if (caps != null) _ = c.gst_caps_ref(caps);
    var dp: ?*DPad = null;
    var is_pc = false;
    var details: [*c]u8 = null;
    var factories: [*c]c.GValueArray = null;
    const Next = enum { done, expose, discarded, unknown, delay };
    const next: Next = blk: {
        if (caps == null or c.gst_caps_is_empty(caps) != 0) break :blk .unknown;
        if (c.gst_caps_is_any(caps) != 0) break :blk .delay;
        if (chain.current_pad == null) chain.current_pad = newPad(s, chain);
        dp = ref(chain.current_pad.?);
        _ = c.gst_pad_set_active(padOf(dp), 1);
        setTarget(dp.?, pad);
        var go: c.gboolean = 1;
        if (c.gst_caps_is_fixed(caps) != 0) c.g_signal_emit(s, signals[SIG_AUTOPLUG_CONTINUE], 0, dp, caps, &go);
        if (go == 0 or finalCaps(s, caps)) break :blk .expose;
        const classification = klassOf(c.gst_element_get_factory(src));
        is_pc = hasText(classification, "Parser") and hasText(classification, "Converter");
        if (!is_pc and c.gst_caps_is_fixed(caps) == 0) {
            c.gst_object_unref(dp);
            dp = null;
            break :blk .delay;
        } else if (!is_pc) {
            c.gst_caps_unref(caps);
            caps = c.gst_pad_get_current_caps(pad);
            if (caps == null) {
                c.gst_object_unref(dp);
                dp = null;
                break :blk .delay;
            }
        }
        c.g_signal_emit(s, signals[SIG_AUTOPLUG_FACTORIES], 0, dp, caps, &factories);
        if (factories == null) break :blk .expose;
        if (factories.*.n_values == 0) {
            c.g_value_array_free(factories);
            factories = null;
            c.gst_object_unref(dp);
            dp = null;
            if (!t.expose_all and rawSubset(caps)) break :blk .discarded;
            break :blk .unknown;
        }
        var sorted: [*c]c.GValueArray = null;
        c.g_signal_emit(s, signals[SIG_AUTOPLUG_SORT], 0, dp, caps, factories, &sorted);
        if (sorted != null) {
            c.g_value_array_free(factories);
            factories = sorted;
        }
        if (!t.expose_all and c.gst_caps_is_fixed(caps) != 0 and decoderWouldDiscard(s, dp.?, factories)) {
            c.gst_object_unref(dp);
            dp = null;
            c.g_value_array_free(factories);
            factories = null;
            break :blk .discarded;
        }
        if (is_pc) {
            var filter = c.gst_caps_new_empty();
            var i: c.guint = 0;
            while (i < factories.*.n_values) : (i += 1) {
                const f: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(factories, i))));
                if (c.gst_element_get_factory(src) == f or c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_PARSER) != 0) continue;
                var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
                while (tl) |n| : (tl = n.next) {
                    const tp: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
                    if (tp.direction != c.GST_PAD_SINK or tp.presence != c.GST_PAD_ALWAYS) continue;
                    const tcaps = c.gst_static_pad_template_get_caps(tp);
                    filter = c.gst_caps_merge(filter, c.gst_caps_intersect_full(tcaps, caps, c.GST_CAPS_INTERSECT_FIRST));
                    c.gst_caps_unref(tcaps);
                }
            }
            filter = c.gst_caps_merge(filter, c.gst_caps_ref(caps));
            var cf: ?*c.GstElement = null;
            if (firstElem(chain)) |pe| {
                pe.capsfilter = c.gst_element_factory_make("capsfilter", null);
                cf = pe.capsfilter;
            } else {
                const pe = A.create(Elem) catch @panic("oom");
                pe.* = .{ .element = c.gst_element_factory_make("capsfilter", null) };
                cf = pe.element;
                chain.elements = c.g_list_prepend(chain.elements, pe);
            }
            c.g_object_set(gobj(cf), "caps", filter, N);
            c.gst_caps_unref(filter);
            _ = c.gst_element_set_state(cf, c.GST_STATE_PAUSED);
            _ = c.gst_bin_add(binOf(s), ref(cf.?));
            setTarget(dp.?, null);
            const sp = c.gst_element_get_static_pad(cf, "sink");
            _ = c.gst_pad_link_full(pad, sp, c.GST_PAD_LINK_CHECK_NOTHING);
            c.gst_object_unref(sp);
            const fp = c.gst_element_get_static_pad(cf, "src");
            setTarget(dp.?, fp);
            pad = fp;
            c.gst_caps_unref(caps);
            caps = c.gst_pad_get_current_caps(pad);
            if (caps == null) {
                c.gst_object_unref(dp);
                dp = null;
                c.g_value_array_free(factories);
                factories = null;
                break :blk .delay;
            }
        }
        const ok = connectPad(s, src, dp.?, pad, caps, factories, chain, &details);
        if (is_pc) c.gst_object_unref(pad);
        c.gst_object_unref(dp);
        dp = null;
        c.g_value_array_free(factories);
        factories = null;
        if (!ok) break :blk .unknown;
        c.gst_caps_unref(caps);
        break :blk .done;
    };
    switch (next) {
        .done => return false,
        .expose => {
            c.gst_object_unref(dp);
            c.gst_caps_unref(caps);
            return true;
        },
        .discarded => {
            chain.deadend = true;
            chain.endcaps = caps;
            _ = c.gst_object_replace(@ptrCast(&chain.current_pad), null);
            exposeIfComplete(s);
            asyncDone(s);
            return false;
        },
        .unknown => {
            chain.deadend_details = details;
            chain.deadend = true;
            chain.endcaps = caps;
            _ = c.gst_object_replace(@ptrCast(&chain.current_pad), null);
            _ = c.gst_element_post_message(elem(s), c.gst_missing_decoder_message_new(elem(s), caps));
            c.g_signal_emit(s, signals[SIG_UNKNOWN_TYPE], 0, pad, caps);
            exposeIfComplete(s);
            if (src == t.typefind) {
                if (caps == null or c.gst_caps_is_empty(caps) != 0)
                    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_TYPE_NOT_FOUND, c.g_strdup(tr("Could not determine type of stream")), null, FILE, "analyze_new_pad", 1969);
                asyncDone(s);
            }
            return false;
        },
        .delay => {
            delayPad(chain, pad);
            if (is_pc) c.gst_object_unref(pad);
            if (caps != null) c.gst_caps_unref(caps);
            return false;
        },
    }
}

fn addFilter(s: *Self, e: ?*c.GstElement) void {
    cm.lock(s);
    st(s).filtered = c.g_list_prepend(st(s).filtered, e);
    cm.unlock(s);
}

fn removeFilter(s: *Self, e: ?*c.GstElement, err: ?*[*c]c.GstMessage) void {
    const t = st(s);
    cm.lock(s);
    defer cm.unlock(s);
    t.filtered = c.g_list_remove(t.filtered, e);
    if (err) |x| x.* = null;
    var l = t.filtered_errors;
    while (l != null) {
        const msg: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        if (msg.*.src == cm.obj(e)) {
            if (err) |x| _ = c.gst_message_replace(x, msg);
            c.gst_message_unref(msg);
            t.filtered_errors = c.g_list_delete_link(t.filtered_errors, l);
            l = t.filtered_errors;
        } else l = l.*.next;
    }
}

const Sticky = struct { ok: bool, peer: ?*c.GstPad };

fn sendSticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *Sticky = @ptrCast(@alignCast(data));
    if (c.gst_pad_send_event(d.peer, c.gst_event_ref(ev.*)) == 0) d.ok = false;
    return @intFromBool(d.ok);
}

fn sendStickyEvents(pad: ?*c.GstPad) bool {
    var d: Sticky = .{ .ok = true, .peer = c.gst_pad_get_peer(pad) };
    _ = c.gst_pad_sticky_events_foreach(pad, sendSticky, &d);
    c.gst_object_unref(d.peer);
    return d.ok;
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

fn appendFailure(details: *c.GString, s: *Self, element: ?*c.GstElement, comptime what: []const u8) void {
    var msg: [*c]c.GstMessage = null;
    removeFilter(s, element, &msg);
    if (msg != null) {
        const es = errorText(msg);
        c.g_string_append_printf(details, what ++ ":\n%s", cm.obj(element).name, es);
        c.gst_message_unref(msg);
        c.g_free(es);
    } else c.g_string_append_printf(details, what ++ "", cm.obj(element).name);
}

fn demuxSpeed(s: *Self, e: ?*c.GstElement) void {
    cm.lock(s);
    const speed = st(s).speed / 1000;
    cm.unlock(s);
    const spec = c.g_object_class_find_property(classOf(e), "connection-speed") orelse return;
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

fn updateSpeed(s: *Self) void {
    const root = st(s).chain orelse return;
    var demux: ?*c.GstElement = null;
    chainLock(root);
    if (root.adaptive) demux = ref(firstElem(root).?.element.?);
    chainUnlock(root);
    if (demux) |d| {
        demuxSpeed(s, d);
        c.gst_object_unref(d);
    }
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

const ToExpose = struct { chain: *Chain, pad: ?*c.GstPad };

fn connectPad(s: *Self, src_in: ?*c.GstElement, dp: *DPad, pad_in: ?*c.GstPad, caps: [*c]c.GstCaps, factories: [*c]c.GValueArray, chain: *Chain, deadend: *[*c]u8) bool {
    if (!cm.that(factories != null, "connect_pad", "factories != NULL")) return false;
    if (!cm.that(factories.*.n_values > 0, "connect_pad", "factories->n_values > 0")) return false;
    const t = st(s);
    var src = src_in;
    var pad = pad_in;
    var res = false;
    var mqpad: ?*c.GstPad = null;
    defer if (mqpad) |x| c.gst_object_unref(x);
    if (chain.parent != null and chain.elements == null) {
        const g = chain.parent.?;
        chain.probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_FLUSH, demuxerSourceProbe, g, null);
        setTarget(dp, null);
        mqpad = controlDemuxerPad(g, pad) orelse {
            deadend.* = null;
            return false;
        };
        src = g.mq;
        _ = c.gst_pad_sticky_events_foreach(pad, copySticky, mqpad);
        pad = mqpad;
        setTarget(dp, pad);
    }
    const details = c.g_string_new("");
    defer deadend.* = c.g_string_free(details, @intFromBool(details.*.len == 0 or res));
    while (factories.*.n_values > 0) {
        setTarget(dp, pad);
        const factory: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(factories, 0))));
        _ = c.g_object_ref(factory);
        defer c.g_object_unref(factory);
        _ = c.g_value_array_remove(factories, 0);
        if (c.gst_caps_is_fixed(caps) != 0) {
            var skip = false;
            var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(factory);
            while (tl) |n| : (tl = n.next) {
                const tp: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
                if (tp.direction != c.GST_PAD_SINK) continue;
                const tc = c.gst_static_caps_get(&tp.static_caps);
                const sub = c.gst_caps_is_subset(caps, tc) != 0;
                c.gst_caps_unref(tc);
                if (!sub) {
                    skip = true;
                    break;
                }
            }
            if (skip) continue;
        }
        const is_parser = hasText(klassOf(factory), "Parser");
        if (is_parser) {
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
        c.g_signal_emit(s, signals[SIG_AUTOPLUG_SELECT], 0, dp, caps, factory, &ret);
        if (ret == flags.SELECT_EXPOSE) {
            exposePad(s, src, dp, pad, caps, chain);
            res = true;
            return res;
        }
        if (ret == flags.SELECT_SKIP) continue;
        setTarget(dp, null);
        const fname = cm.obj(factory).name;
        const element = c.gst_element_factory_create(factory, null) orelse {
            c.g_string_append_printf(details, "Could not create an element from %s\n", fname);
            continue;
        };
        addFilter(s, element);
        _ = c.gst_element_set_locked_state(element, 1);
        if (c.gst_bin_add(binOf(s), element) == 0) {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Couldn't add %s to the bin\n", cm.obj(element).name);
            c.gst_object_unref(element);
            continue;
        }
        const sinkpad = findSinkPad(element) orelse {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Element %s doesn't have a sink pad", cm.obj(element).name);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        };
        if (c.gst_pad_link_full(pad, sinkpad, c.GST_PAD_LINK_CHECK_NOTHING) != c.GST_PAD_LINK_OK) {
            removeFilter(s, element, null);
            c.g_string_append_printf(details, "Link failed on pad %s:%s", cm.padParentName(@as(?*c.GstPad, sinkpad)), cm.padName(@as(?*c.GstPad, sinkpad)));
            c.gst_object_unref(sinkpad);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        if (c.gst_element_set_state(element, c.GST_STATE_READY) == c.GST_STATE_CHANGE_FAILURE) {
            appendFailure(details, s, element, "Couldn't set %s to READY");
            c.gst_object_unref(sinkpad);
            _ = c.gst_bin_remove(binOf(s), element);
            continue;
        }
        if (c.gst_pad_query_accept_caps(sinkpad, caps) == 0) {
            appendFailure(details, s, element, "Element %s does not accept caps");
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
        chain.adaptive = isAdaptive(element);
        const is_decoder = hasText(klassOf(factory), "Decoder");
        if (chain.parent) |g| if (g.parent) |pc| if (pc.adaptive and (is_parser or is_decoder)) {
            chain.demuxer = true;
        };
        if (chain.parent == null and (is_parser or is_decoder) and t.use_buffering) chain.demuxer = true;
        chainUnlock(chain);
        if (chain.demuxer) demuxSpeed(s, element);
        var subtitle = false;
        if (c.g_object_class_find_property(classOf(element), "subtitle-encoding")) |spec| {
            if (spec.*.value_type == c.G_TYPE_STRING) {
                c.g_mutex_lock(&t.subtitle_lock);
                c.g_object_set(gobj(element), "subtitle-encoding", t.encoding, N);
                c.g_mutex_unlock(&t.subtitle_lock);
                subtitle = true;
            }
        }
        var to_connect = connectElement(pelem, chain);
        var to_expose: std.ArrayList(ToExpose) = .empty;
        defer to_expose.deinit(A);
        while (to_connect != null) {
            const op: ?*c.GstPad = @ptrCast(@alignCast(to_connect.*.data));
            const oc = padCaps(op);
            var nc: *Chain = chain;
            if (analyzeNewPad(s, pelem.element, op, oc, chain, &nc)) to_expose.insert(A, 0, .{ .chain = nc, .pad = ref(op.?) }) catch @panic("oom");
            if (oc != null) c.gst_caps_unref(oc);
            c.gst_object_unref(op);
            to_connect = c.g_list_delete_link(to_connect, to_connect);
        }
        cm.streamLock(sinkpad);
        if (c.gst_element_set_state(element, c.GST_STATE_PAUSED) == c.GST_STATE_CHANGE_FAILURE or !sendStickyEvents(pad)) {
            cm.streamUnlock(sinkpad);
            for (to_expose.items) |x| c.gst_object_unref(x.pad);
            to_expose.clearRetainingCapacity();
            appendFailure(details, s, element, "Couldn't set %s to PAUSED");
            unwindTo(s, chain, element);
            continue;
        }
        cm.streamUnlock(sinkpad);
        removeFilter(s, element, null);
        _ = c.gst_element_set_locked_state(element, 0);
        if (subtitle) {
            c.g_mutex_lock(&t.subtitle_lock);
            t.subtitles = c.g_list_prepend(t.subtitles, element);
            c.g_mutex_unlock(&t.subtitle_lock);
        }
        for (to_expose.items) |x| {
            const oc = padCaps(x.pad);
            exposePad(s, pelem.element, x.chain.current_pad.?, x.pad, oc, x.chain);
            if (oc != null) c.gst_caps_unref(oc);
            c.gst_object_unref(x.pad);
        }
        res = true;
        break;
    }
    return res;
}

fn findSinkPad(e: ?*c.GstElement) ?*c.GstPad {
    const it = c.gst_element_iterate_sink_pads(e);
    var item = std.mem.zeroes(c.GValue);
    var pad: ?*c.GstPad = null;
    if (c.gst_iterator_next(it, &item) == c.GST_ITERATOR_OK) pad = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    return pad;
}

fn padCaps(pad: ?*c.GstPad) [*c]c.GstCaps {
    const caps = c.gst_pad_get_current_caps(pad);
    return if (caps != null) caps else c.gst_pad_query_caps(pad, null);
}

fn connectElement(pelem: *Elem, chain: *Chain) [*c]c.GList {
    const e = pelem.element;
    var dynamic = false;
    var out: [*c]c.GList = null;
    var l = @as(*c.GstElementClass, @ptrCast(@alignCast(classOf(e)))).padtemplates;
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

fn exposePad(s: *Self, src: ?*c.GstElement, dp: *DPad, pad_in: ?*c.GstPad, caps: [*c]c.GstCaps, chain: *Chain) void {
    var pad = pad_in;
    var mqpad: ?*c.GstPad = null;
    if (chain.parent) |g| if (chain.elements == null and src != g.mq) {
        setTarget(dp, null);
        mqpad = controlDemuxerPad(g, pad) orelse return;
        pad = mqpad;
        setTarget(dp, pad);
    };
    activatePad(dp, chain);
    chain.endpad = ref(dp);
    chain.endcaps = c.gst_caps_ref(caps);
    exposeIfComplete(s);
    if (mqpad) |x| c.gst_object_unref(x);
}

fn upstreamSeekable(pad: ?*c.GstPad) bool {
    const q = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
    defer c.gst_query_unref(q);
    if (c.gst_pad_peer_query(pad, q) == 0) return false;
    var seekable: c.gboolean = 0;
    var start: i64 = -1;
    var stop: i64 = -1;
    c.gst_query_parse_seeking(q, null, &seekable, &start, &stop);
    if (seekable != 0 and stop == -1) _ = c.gst_pad_peer_query_duration(pad, c.GST_FORMAT_BYTES, &stop);
    if (seekable != 0 and (start != 0 or stop <= start)) return false;
    return seekable != 0;
}

fn typeFound(tf: ?*c.GstElement, _: c.guint, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    if (c.gst_structure_has_name(c.gst_caps_get_structure(caps, 0), "text/plain") != 0) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_WRONG_TYPE, c.g_strdup(tr("This appears to be a text file")), c.g_strdup("decodebin cannot decode plain text files"), FILE, "type_found", 2910);
        return;
    }
    const pad = c.gst_element_get_static_pad(tf, "src");
    const sink = c.gst_element_get_static_pad(tf, "sink");
    cm.streamLock(sink);
    if (!t.have_type and t.chain == null) {
        t.have_type = true;
        const root = newChain(s, null, pad);
        t.chain = root;
        const held = chainRef(root);
        if (analyzeNewPad(s, tf, pad, caps, root, null)) exposePad(s, tf, root.current_pad.?, pad, caps, root);
        chainUnref(held);
    }
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
    cm.streamLock(pad);
    defer cm.streamUnlock(pad);
    if (c.gst_pad_is_active(pad) == 0) return;
    const caps = padCaps(pad);
    var nc: *Chain = ch;
    if (analyzeNewPad(s, e, pad, caps, ch, &nc)) exposePad(s, e, nc.current_pad.?, pad, caps, nc);
    if (caps != null) c.gst_caps_unref(caps);
}

fn lastGroupPeer(g: *Group) ?*c.GstPad {
    const pc = g.parent orelse return null;
    if (pc.next_groups == null) return null;
    const last: *Group = @ptrCast(@alignCast(c.g_list_last(pc.next_groups).*.data));
    if (last.reqpads == null) return null;
    return c.gst_pad_get_peer(@ptrCast(@alignCast(last.reqpads.*.data)));
}

fn sinkEventProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const g: *Group = @ptrCast(@alignCast(data));
    if (c.gst_pad_get_peer(pad)) |peer| {
        c.gst_object_unref(peer);
        return c.GST_PAD_PROBE_OK;
    }
    const other = lastGroupPeer(g) orelse return c.GST_PAD_PROBE_OK;
    defer c.gst_object_unref(other);
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    if (c.gst_pad_send_event(other, c.gst_event_ref(ev)) != 0) {
        c.gst_event_unref(ev);
        return c.GST_PAD_PROBE_HANDLED;
    }
    return c.GST_PAD_PROBE_OK;
}

fn sinkQueryProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const g: *Group = @ptrCast(@alignCast(data));
    if (c.gst_pad_get_peer(pad)) |peer| {
        c.gst_object_unref(peer);
        return c.GST_PAD_PROBE_OK;
    }
    const other = lastGroupPeer(g) orelse return c.GST_PAD_PROBE_OK;
    defer c.gst_object_unref(other);
    return if (c.gst_pad_query(other, @ptrCast(@alignCast(info.*.data))) != 0) c.GST_PAD_PROBE_HANDLED else c.GST_PAD_PROBE_OK;
}

fn demuxerSourceProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const g: *Group = @ptrCast(@alignCast(data));
    const pc = g.parent.?;
    if (pc.active_group == g) return c.GST_PAD_PROBE_OK;
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    const kind = cm.eventType(ev);
    if (kind != c.GST_EVENT_FLUSH_START and kind != c.GST_EVENT_FLUSH_STOP) return c.GST_PAD_PROBE_OK;
    var l = pc.active_group.?.reqpads;
    while (l != null) : (l = l.*.next) _ = c.gst_pad_send_event(@ptrCast(@alignCast(l.*.data)), c.gst_event_ref(ev));
    var n = pc.next_groups;
    while (n != null) : (n = n.*.next) {
        const other: *Group = @ptrCast(@alignCast(n.*.data));
        if (other == g) continue;
        var r = other.reqpads;
        while (r != null) : (r = r.*.next) _ = c.gst_pad_send_event(@ptrCast(@alignCast(r.*.data)), c.gst_event_ref(ev));
    }
    flushChain(pc, kind == c.GST_EVENT_FLUSH_START);
    return c.GST_PAD_PROBE_OK;
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
    queueSize(g.bin, g.mq, false, if (g.parent) |p| p.seekable else true);
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
    var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(classOf(e))));
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

fn isAdaptive(e: ?*c.GstElement) bool {
    const k = klassOf(c.gst_element_get_factory(e));
    return hasText(k, "Demux") and hasText(k, "Adaptive");
}

fn resetBuffering(s: *Self) void {
    const t = st(s);
    if (!t.use_buffering) return;
    const root = t.chain orelse return;
    chainLock(root);
    _ = chainResetBuffering(root);
    chainUnlock(root);
}

fn chainResetBuffering(ch: *Chain) bool {
    const g = ch.active_group orelse return false;
    return groupResetBuffering(g);
}

fn currentGroup(ch: *Chain) ?*Group {
    if (ch.next_groups == null) if (ch.active_group) |g| if (g.overrun and !g.no_more_pads) return null;
    if (ch.next_groups != null) {
        const g: *Group = @ptrCast(@alignCast(ch.next_groups.*.data));
        if (g.overrun and !g.no_more_pads) return null;
    }
    var group: ?*Group = null;
    if (ch.active_group == null) {
        group = newGroup(ch.bin, ch);
        ch.active_group = group;
    } else if (!ch.active_group.?.overrun and !ch.active_group.?.no_more_pads) {
        group = ch.active_group;
    } else {
        var l = ch.next_groups;
        while (l != null) : (l = l.*.next) {
            const g: *Group = @ptrCast(@alignCast(l.*.data));
            if (!g.overrun and !g.no_more_pads) {
                group = g;
                break;
            }
        }
    }
    if (group == null) {
        group = newGroup(ch.bin, ch);
        ch.next_groups = c.g_list_append(ch.next_groups, group);
    }
    return group;
}

fn chainRef(ch: *Chain) *Chain {
    _ = c.g_atomic_int_add(&ch.refs, 1);
    return ch;
}

fn chainUnref(ch: *Chain) void {
    if (c.g_atomic_int_dec_and_test(&ch.refs) != 0) {
        c.g_mutex_clear(&ch.lock);
        A.destroy(ch);
    }
}

fn freeChainInternal(ch: *Chain, hide: bool) void {
    const s = ch.bin;
    const t = st(s);
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
        c.g_mutex_lock(&t.subtitle_lock);
        t.subtitles = c.g_list_remove(t.subtitles, e);
        c.g_mutex_unlock(&t.subtitle_lock);
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
        if (ep.exposed != 0) _ = c.gst_element_remove_pad(elem(s), padOf(ep));
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
    if (!hide) chainUnref(ch);
}

fn freeChain(ch: *Chain) void {
    freeChainInternal(ch, false);
}

fn newChain(s: *Self, parent: ?*Group, pad: ?*c.GstPad) *Chain {
    const ch = A.create(Chain) catch @panic("oom");
    ch.* = .{ .parent = parent, .bin = s };
    c.g_mutex_init(&ch.lock);
    ch.pad = ref(pad.?);
    return ch;
}

fn overrun(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    g.overrun = true;
    queueSize(g.bin, g.mq, false, if (g.parent) |p| p.seekable else true);
    exposeIfComplete(g.bin);
}

fn freeGroupInternal(g: *Group, hide: bool) void {
    const s = g.bin;
    if (!hide) {
        var l = g.demux_pads;
        while (l != null) : (l = l.*.next) {
            const d: *DemuxPad = @ptrCast(@alignCast(l.*.data));
            if (c.g_weak_ref_get(&d.weak)) |sp| {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(sp));
                c.gst_pad_remove_probe(pad, d.event_probe);
                c.gst_pad_remove_probe(pad, d.query_probe);
                c.g_weak_ref_clear(&d.weak);
                c.gst_object_unref(pad);
            }
            A.destroy(d);
        }
        c.g_list_free(g.demux_pads);
        g.demux_pads = null;
    }
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        freeChainInternal(@ptrCast(@alignCast(l.*.data)), hide);
        if (!hide) l.*.data = null;
    }
    if (!hide) {
        c.g_list_free(g.children);
        g.children = null;
        l = g.reqpads;
        while (l != null) : (l = l.*.next) {
            const p: ?*c.GstPad = @ptrCast(@alignCast(l.*.data));
            c.gst_element_release_request_pad(g.mq, p);
            c.gst_object_unref(p);
            l.*.data = null;
        }
        c.g_list_free(g.reqpads);
        g.reqpads = null;
    }
    if (g.mq) |mq| {
        if (g.overrun_id != 0) {
            c.g_signal_handler_disconnect(mq, g.overrun_id);
            g.overrun_id = 0;
        }
        if (cm.obj(mq).parent == cm.obj(s)) _ = c.gst_bin_remove(binOf(s), mq);
        if (!hide) {
            _ = c.gst_element_set_state(mq, c.GST_STATE_NULL);
            c.gst_object_unref(mq);
            g.mq = null;
        }
    }
    if (!hide) A.destroy(g);
}

fn freeHidden(data: c.gpointer) callconv(.c) c.gpointer {
    const list: [*c]c.GList = @ptrCast(@alignCast(data));
    var l = list;
    while (l != null) : (l = l.*.next) freeGroupInternal(@ptrCast(@alignCast(l.*.data)), false);
    c.g_list_free(list);
    return null;
}

fn startFreeHidden(ch: *Chain) void {
    const t = st(ch.bin);
    const old = ch.old_groups;
    if (old == null) return;
    c.g_mutex_lock(&t.cleanup_lock);
    defer c.g_mutex_unlock(&t.cleanup_lock);
    if (t.cleanup_thread) |th| {
        _ = c.g_thread_join(th);
        t.cleanup_thread = null;
    }
    ch.old_groups = null;
    if (t.shutdown) {
        t.cleanup_groups = c.g_list_concat(t.cleanup_groups, old);
        return;
    }
    var err: [*c]c.GError = null;
    const th = c.g_thread_try_new("free-hidden-groups", freeHidden, old, &err);
    if (th == null or err != null) {
        c.g_clear_error(&err);
        ch.old_groups = old;
        return;
    }
    t.cleanup_thread = th;
}

fn queueSize(s: *Self, mq: ?*c.GstElement, preroll: bool, seekable: bool) void {
    var buffering: c.gboolean = 0;
    c.g_object_get(gobj(mq), "use-buffering", &buffering, N);
    queueSizeFull(s, mq, buffering != 0, preroll, seekable);
}

fn queueSizeFull(s: *Self, mq: ?*c.GstElement, buffering: bool, preroll: bool, seekable: bool) void {
    const t = st(s);
    var bytes: c.guint = 0;
    var buffers: c.guint = 0;
    var time: u64 = 0;
    if (preroll or buffering) {
        bytes = if (preroll or t.max_bytes == 0) PRE_BYTES else t.max_bytes;
        buffers = if (preroll or t.max_buffers == 0) PRE_BUFFERS else t.max_buffers;
        if (preroll or t.max_time == 0) {
            time = if (t.use_buffering and !preroll) 5 * SECOND else if (seekable) PRE_TIME_SEEKABLE else PRE_TIME_UNSEEKABLE;
        } else time = t.max_time;
    } else {
        bytes = if (t.use_buffering) 0 else if (t.max_bytes == 0) PLAY_BYTES else t.max_bytes;
        buffers = if (t.max_buffers == 0) PLAY_BUFFERS else t.max_buffers;
        time = if (t.use_buffering) 0 else if (t.max_time == 0) PLAY_TIME else t.max_time;
    }
    c.g_object_set(gobj(mq), "max-size-bytes", bytes, "max-size-time", time, "max-size-buffers", buffers, N);
}

fn newGroup(s: *Self, parent: ?*Chain) ?*Group {
    const g = A.create(Group) catch @panic("oom");
    g.* = .{ .bin = s, .parent = parent };
    g.mq = c.gst_element_factory_make("multiqueue", null) orelse {
        _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), "multiqueue"));
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no multiqueue!"), FILE, "gst_decode_group_new", 3912);
        A.destroy(g);
        return null;
    };
    var seekable = false;
    if (parent) |p| if (p.demuxer) {
        if (c.gst_element_get_static_pad(firstElem(p).?.element, "sink")) |pad| {
            seekable = upstreamSeekable(pad);
            p.seekable = seekable;
            c.gst_object_unref(pad);
        }
    };
    queueSizeFull(s, g.mq, false, true, seekable);
    g.overrun_id = c.g_signal_connect_data(g.mq, "overrun", @ptrCast(&overrun), g, null, 0);
    _ = c.gst_element_set_state(g.mq, c.GST_STATE_PAUSED);
    _ = c.gst_bin_add(binOf(s), ref(g.mq.?));
    return g;
}

fn controlDemuxerPad(g: *Group, pad: ?*c.GstPad) ?*c.GstPad {
    const mq = g.mq orelse return null;
    const sink = c.gst_element_request_pad_simple(mq, "sink_%u") orelse return null;
    defer c.gst_object_unref(sink);
    if (c.gst_pad_link_full(pad, sink, c.GST_PAD_LINK_CHECK_NOTHING) != c.GST_PAD_LINK_OK) {
        c.gst_element_release_request_pad(mq, sink);
        return null;
    }
    const it = c.gst_pad_iterate_internal_links(sink);
    var item = std.mem.zeroes(c.GValue);
    var src: ?*c.GstPad = null;
    if (it != null and c.gst_iterator_next(it, &item) == c.GST_ITERATOR_OK) src = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
    defer {
        if (item.g_type != 0) c.g_value_unset(&item);
        if (it != null) c.gst_iterator_free(it);
    }
    if (src == null) {
        c.gst_element_release_request_pad(mq, sink);
        return null;
    }
    const pc = g.parent.?;
    chainLock(pc);
    const d = A.create(DemuxPad) catch @panic("oom");
    d.* = .{};
    c.g_weak_ref_init(&d.weak, null);
    d.event_probe = c.gst_pad_add_probe(sink, c.GST_PAD_PROBE_TYPE_EVENT_UPSTREAM, sinkEventProbe, g, null);
    d.query_probe = c.gst_pad_add_probe(sink, c.GST_PAD_PROBE_TYPE_QUERY_UPSTREAM, sinkQueryProbe, g, null);
    c.g_weak_ref_set(&d.weak, sink);
    g.demux_pads = c.g_list_prepend(g.demux_pads, d);
    g.reqpads = c.g_list_prepend(g.reqpads, c.gst_object_ref(sink));
    chainUnlock(pc);
    return src;
}

fn groupIsComplete(g: *Group) bool {
    if (!g.overrun and !g.no_more_pads) return false;
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        if (!chainIsComplete(@ptrCast(@alignCast(l.*.data)))) return false;
    }
    return true;
}

fn exposable(p: *DPad) bool {
    if (p.blocked != 0 or p.exposed != 0) return true;
    return c.gst_pad_has_current_caps(padOf(p)) != 0;
}

fn chainIsComplete(ch: *Chain) bool {
    chainLock(ch);
    defer chainUnlock(ch);
    if (st(ch.bin).shutdown) return false;
    if (ch.deadend) return true;
    if (ch.endpad) |ep| if (exposable(ep)) return true;
    if (ch.demuxer) if (ch.active_group) |g| if (groupIsComplete(g)) return true;
    return false;
}

fn flushGroup(g: *Group, flushing: bool) void {
    if (g.drained == flushing) return;
    var l = g.children;
    while (l != null) : (l = l.*.next) flushChain(@ptrCast(@alignCast(l.*.data)), flushing);
    g.drained = flushing;
}

fn hideGroup(ch: *Chain, g: *Group) void {
    freeGroupInternal(g, true);
    ch.old_groups = c.g_list_prepend(ch.old_groups, g);
}

fn flushChain(ch: *Chain, flushing: bool) void {
    if (ch.drained == flushing) return;
    if (!flushing and ch.next_groups != null) {
        const target: *Group = @ptrCast(@alignCast(c.g_list_last(ch.next_groups).*.data));
        startFreeHidden(ch);
        hideGroup(ch, ch.active_group.?);
        ch.active_group = target;
        var l = ch.next_groups;
        while (l != null) : (l = l.*.next) {
            const g: *Group = @ptrCast(@alignCast(l.*.data));
            if (g != target) hideGroup(ch, g);
        }
        c.g_list_free(ch.next_groups);
        ch.next_groups = null;
    }
    if (ch.active_group) |g| flushGroup(g, flushing);
    var l = ch.next_groups;
    while (l != null) : (l = l.*.next) flushGroup(@ptrCast(@alignCast(l.*.data)), flushing);
    ch.drained = flushing;
}

fn drainGroup(g: *Group, pad: ?*DPad, last: *bool, drained: *bool, switched: *bool) bool {
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

fn drainChains(ch: *Chain, pad: ?*DPad, last: *bool, drained: *bool, switched: *bool) bool {
    var handled = false;
    chainLock(ch);
    if (ch.probe != 0) {
        c.gst_pad_remove_probe(ch.pad, ch.probe);
        ch.probe = 0;
    }
    body: {
        if (ch.drained) break :body;
        if (ch.endpad) |ep| {
            if (pad != null and @as(*anyopaque, ch) == pad.?.chain) {
                pad.?.drained = 1;
                handled = true;
            }
            ch.drained = ep.drained != 0;
            break :body;
        }
        if (ch.next_groups != null) last.* = false;
        if (ch.active_group) |g| {
            var sub = false;
            handled = drainGroup(g, pad, last, &sub, switched);
            if ((handled or pad == null) and sub and !switched.*) {
                if (ch.next_groups != null) {
                    hideGroup(ch, g);
                    ch.active_group = @ptrCast(@alignCast(ch.next_groups.*.data));
                    ch.next_groups = c.g_list_delete_link(ch.next_groups, ch.next_groups);
                    startFreeHidden(ch);
                    switched.* = true;
                    ch.drained = false;
                } else ch.drained = true;
            } else if (sub and ch.next_groups == null) drained.* = true;
        }
    }
    chainUnlock(ch);
    drained.* = ch.drained;
    if (drained.* and ch.parent == null) c.g_signal_emit(ch.bin, signals[SIG_DRAINED], 0);
    return handled;
}

fn handleEos(p: *DPad) bool {
    var last = true;
    var switched = false;
    var drained = false;
    const s = chainOf(p).bin;
    if (c.gst_pad_get_sticky_event(padOf(p), c.GST_EVENT_STREAM_START, 0)) |ev| {
        var gid: c.guint = 0;
        if (c.gst_event_parse_group_id(ev, &gid) != 0) {
            if (c.gst_pad_get_peer(padOf(p))) |peer| {
                _ = c.gst_pad_send_event(peer, c.gst_event_new_stream_group_done(gid));
                c.gst_object_unref(peer);
            }
        }
        c.gst_event_unref(ev);
    }
    exposeLock(s);
    if (st(s).chain) |root| {
        _ = drainChains(root, p, &last, &drained, &switched);
        if (switched and chainIsComplete(root)) _ = expose(s);
    }
    exposeUnlock(s);
    return last;
}

fn groupResetBuffering(g: *Group) bool {
    var ret = true;
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        const ch: *Chain = @ptrCast(@alignCast(l.*.data));
        chainLock(ch);
        if (!chainResetBuffering(ch)) ret = false;
        chainUnlock(ch);
    }
    const t = st(g.bin);
    queueSizeFull(g.bin, g.mq, !ret, false, if (g.parent) |p| p.seekable else true);
    if (ret) {
        c.g_object_set(gobj(g.mq), "use-buffering", @as(c.gboolean, 0), N);
    } else c.g_object_set(gobj(g.mq), "use-buffering", @as(c.gboolean, 1), "low-percent", t.low_percent, "high-percent", t.high_percent, N);
    return true;
}

fn rank(name: [*c]const u8) c.gint {
    if (c.g_strrstr(name, "video/x-raw") != null) return 0;
    if (c.g_strrstr(name, "video/") != null) return 1;
    if (c.g_strrstr(name, "audio/x-raw") != null) return 2;
    if (c.g_strrstr(name, "audio/") != null) return 3;
    return 4;
}

fn sortEndPads(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const pa: ?*c.GstPad = @ptrCast(@alignCast(@constCast(a)));
    const pb: ?*c.GstPad = @ptrCast(@alignCast(@constCast(b)));
    const ca = padCaps(pa);
    const cb = padCaps(pb);
    var va: c.gint = 0;
    var vb: c.gint = 0;
    if (c.gst_caps_get_size(ca) == 0 or c.gst_caps_get_size(cb) == 0) {
        va = if (c.gst_caps_is_empty(ca) != 0) 7 else 0;
        vb = if (c.gst_caps_is_empty(cb) != 0) 7 else 0;
    } else {
        va = rank(c.gst_structure_get_name(c.gst_caps_get_structure(ca, 0)));
        vb = rank(c.gst_structure_get_name(c.gst_caps_get_structure(cb, 0)));
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

fn linkedCaps(src: ?*c.GstElement, sink: ?*c.GstElement, capsfilter: ?*c.GstElement, srcpad: *?*c.GstPad) [*c]c.GstCaps {
    const it = c.gst_element_iterate_src_pads(src);
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    var caps: [*c]c.GstCaps = null;
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&item)));
                if (c.gst_pad_get_peer(pad)) |peer| {
                    const parent = c.gst_pad_get_parent_element(peer);
                    var done = false;
                    if (parent == sink or (capsfilter != null and parent == capsfilter)) {
                        caps = c.gst_pad_get_current_caps(pad);
                        srcpad.* = ref(pad.?);
                        done = true;
                    }
                    if (parent) |x| c.gst_object_unref(x);
                    c.gst_object_unref(peer);
                    if (done) return caps;
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return caps,
        }
    }
}

fn topology(ch: *Chain) ?*c.GstStructure {
    if ((ch.endpad != null or ch.deadend) and ch.endcaps == null) return null;
    var u = c.gst_structure_new_static_str_empty("stream-topology");
    if ((ch.elements != null or ch.active_group == null) and (ch.endpad != null or ch.deadend)) {
        const s = c.gst_structure_new_static_str_empty("stream-topology");
        c.gst_structure_set(u, "caps", c.gst_caps_get_type(), ch.endcaps, N);
        if (ch.endpad) |ep| {
            c.gst_structure_set(u, "pad", c.gst_pad_get_type(), ep, N);
            const sp = c.gst_ghost_pad_get_target(ghost(ep));
            c.gst_structure_set(u, "element-srcpad", c.gst_pad_get_type(), sp, N);
            c.gst_object_unref(sp);
        }
        c.gst_structure_set(s, "next", c.gst_structure_get_type(), u, N);
        c.gst_structure_free(u);
        u = s;
    } else if (ch.active_group) |g| {
        var list = std.mem.zeroes(c.GValue);
        var item = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&list, c.gst_value_list_get_type());
        _ = c.g_value_init(&item, c.gst_structure_get_type());
        var l = g.children;
        while (l != null) : (l = l.*.next) {
            if (topology(@ptrCast(@alignCast(l.*.data)))) |x| {
                c.gst_value_set_structure(&item, x);
                c.gst_value_list_append_value(&list, &item);
                _ = c.g_value_reset(&item);
                c.gst_structure_free(x);
            }
        }
        c.gst_structure_set_value(u, "next", &list);
        c.g_value_unset(&list);
        c.g_value_unset(&item);
    }
    var l: [*c]c.GList = if (ch.elements != null and ch.elements.*.next != null) ch.elements else null;
    while (l != null and l.*.next != null) : (l = l.*.next) {
        const de: *Elem = @ptrCast(@alignCast(l.*.data));
        const dn: *Elem = @ptrCast(@alignCast(l.*.next.*.data));
        var srcpad: ?*c.GstPad = null;
        const caps = linkedCaps(dn.element, de.element, dn.capsfilter, &srcpad);
        if (caps != null) {
            const s = c.gst_structure_new_static_str_empty("stream-topology");
            c.gst_structure_set(u, "caps", c.gst_caps_get_type(), caps, N);
            c.gst_caps_unref(caps);
            c.gst_structure_set(s, "next", c.gst_structure_get_type(), u, N);
            c.gst_structure_free(u);
            u = s;
        }
        if (srcpad) |p| {
            c.gst_structure_set(u, "element-srcpad", c.gst_pad_get_type(), p, N);
            c.gst_object_unref(p);
        }
    }
    const caps = padCaps(ch.pad);
    if (caps == null) return u;
    c.gst_structure_set(u, "caps", c.gst_caps_get_type(), caps, N);
    c.gst_structure_set(u, "element-srcpad", c.gst_pad_get_type(), ch.pad, N);
    c.gst_caps_unref(caps);
    return u;
}

fn postTopology(s: *Self) void {
    const x = topology(st(s).chain.?) orelse return;
    _ = c.gst_element_post_message(elem(s), c.gst_message_new_element(cm.obj(s), x));
}

fn expose(s: *Self) bool {
    const t = st(s);
    while (true) {
        var endpads: [*c]c.GList = null;
        var missing = false;
        var last = true;
        const details = c.g_string_new("");
        dynLock(s);
        if (t.shutdown) {
            dynUnlock(s);
            _ = c.g_string_free(details, 1);
            return false;
        }
        dynUnlock(s);
        const root = t.chain.?;
        if (!chainExpose(root, &endpads, &missing, details, &last)) {
            c.g_list_free_full(endpads, c.gst_object_unref);
            _ = c.g_string_free(details, 1);
            dynLock(s);
            const down = t.shutdown;
            dynUnlock(s);
            if (!down) c.g_log(null, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", FILE, @as(c_int, 4731), "gst_decode_bin_expose");
            return false;
        }
        if (endpads == null) {
            if (missing) {
                if (details.*.len > 0) {
                    const d = c.g_string_free(details, 0);
                    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup_printf("no suitable plugins found:\n%s", d), FILE, "gst_decode_bin_expose", 4738);
                    c.g_free(d);
                } else {
                    _ = c.g_string_free(details, 1);
                    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no suitable plugins found"), FILE, "gst_decode_bin_expose", 4743);
                }
            } else {
                _ = c.g_string_free(details, 1);
                if (last) {
                    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup("all streams without buffers"), FILE, "gst_decode_bin_expose", 4754);
                } else {
                    var switched = false;
                    var drained = false;
                    _ = drainChains(root, null, &last, &drained, &switched);
                    cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup("all streams without buffers"), FILE, "gst_decode_bin_expose", 4762);
                    if (switched) {
                        if (chainIsComplete(root)) continue;
                        return false;
                    }
                }
            }
            asyncDone(s);
            return false;
        }
        _ = c.g_string_free(details, 1);
        var all = true;
        var l = endpads;
        while (l != null and all) : (l = l.*.next) all = dpad(l.*.data).exposed != 0;
        if (all) {
            c.g_list_free_full(endpads, c.gst_object_unref);
            return true;
        }
        resetBuffering(s);
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = dpad(l.*.data);
            if (p.exposed != 0) setBlocked(p, true);
        }
        endpads = c.g_list_sort(endpads, sortEndPads);
        dynLock(s);
        if (t.shutdown) {
            dynUnlock(s);
            return false;
        }
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = dpad(l.*.data);
            const name = c.g_strdup_printf("src_%u", t.nbpads);
            t.nbpads += 1;
            _ = c.gst_object_set_name(cm.obj(p), name);
            c.g_free(name);
            if (p.exposed == 0) {
                p.exposed = 1;
                if (c.gst_element_add_pad(elem(s), padOf(p)) == 0) {
                    c.g_log(null, c.G_LOG_LEVEL_WARNING, "error adding pad to decodebin");
                    p.exposed = 0;
                }
            }
        }
        dynUnlock(s);
        c.gst_element_no_more_pads(elem(s));
        if (t.post_topology) postTopology(s);
        l = endpads;
        while (l != null) : (l = l.*.next) {
            const p = dpad(l.*.data);
            setBlocked(p, false);
            c.gst_object_unref(p);
        }
        c.g_list_free(endpads);
        asyncDone(s);
        return true;
    }
}

fn chainExpose(ch: *Chain, endpads: *[*c]c.GList, missing: *bool, details: *c.GString, last: *bool) bool {
    if (ch.deadend) {
        if (ch.endcaps != null) {
            if (ch.deadend_details != null) {
                _ = c.g_string_append(details, ch.deadend_details);
                _ = c.g_string_append_c(details, '\n');
            } else {
                const desc = c.gst_pb_utils_get_codec_description(ch.endcaps);
                const cs = c.gst_caps_to_string(ch.endcaps);
                c.g_string_append_printf(details, "Missing decoder: %s (%s)\n", desc, cs);
                c.g_free(cs);
                c.g_free(desc);
            }
            missing.* = true;
        }
        return true;
    }
    if (ch.endpad) |p| {
        if (!exposable(p) and p.exposed == 0) return false;
        endpads.* = c.g_list_prepend(endpads.*, c.gst_object_ref(p));
        return true;
    }
    if (ch.next_groups != null) last.* = false;
    const g = ch.active_group orelse return false;
    if (!g.no_more_pads and !g.overrun) return false;
    if (g.overrun_id != 0) {
        c.g_signal_handler_disconnect(g.mq, g.overrun_id);
        g.overrun_id = 0;
    }
    var l = g.children;
    while (l != null) : (l = l.*.next) {
        if (!chainExpose(@ptrCast(@alignCast(l.*.data)), endpads, missing, details, last)) return false;
    }
    return true;
}

fn sourceBlocked(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const p = dpad(data);
    var ret: c.GstPadProbeReturn = c.GST_PAD_PROBE_OK;
    if ((info.*.type & c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM) != 0) {
        const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
        if (!cm.eventSerialized(ev)) return c.GST_PAD_PROBE_PASS;
        if (cm.eventSticky(ev) and cm.eventType(ev) != c.GST_EVENT_EOS) {
            _ = c.gst_pad_push_event(padOf(p), c.gst_event_ref(ev));
            ret = c.GST_PAD_PROBE_PASS;
            if (cm.eventType(ev) != c.GST_EVENT_CAPS) return ret;
        }
    } else if ((info.*.type & c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM) != 0) {
        if (!cm.querySerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
        if (c.gst_pad_has_current_caps(pad) == 0) return c.GST_PAD_PROBE_PASS;
    }
    p.blocked = 1;
    exposeIfComplete(chainOf(p).bin);
    return ret;
}

fn sourceEvent(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (cm.eventType(info.*.data) != c.GST_EVENT_EOS) return c.GST_PAD_PROBE_OK;
    return if (handleEos(dpad(data))) c.GST_PAD_PROBE_OK else c.GST_PAD_PROBE_DROP;
}

fn setBlocked(p: *DPad, blocked: bool) void {
    const s = p.bin.?;
    const t = st(s);
    dynLock(s);
    defer dynUnlock(s);
    const opad = c.gst_ghost_pad_get_target(ghost(p)) orelse return;
    defer c.gst_object_unref(opad);
    if (!blocked or !t.shutdown) {
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
        if (t.shutdown) {
            _ = c.gst_pad_set_active(padOf(p), 0);
        } else {
            _ = c.gst_object_ref(p);
            t.blocked_pads = c.g_list_prepend(t.blocked_pads, p);
        }
    } else if (c.g_list_find(t.blocked_pads, p)) |l| {
        c.gst_object_unref(p);
        t.blocked_pads = c.g_list_delete_link(t.blocked_pads, l);
    }
}

fn activatePad(p: *DPad, ch: *Chain) void {
    p.chain = ch;
    _ = c.gst_pad_set_active(padOf(p), 1);
    setBlocked(p, true);
    _ = c.gst_pad_add_probe(padOf(p), c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, sourceEvent, p, null);
}

fn dpadEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev: ?*c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_SEEK and parent != null) {
        const s = me(parent);
        if (st(s).chain) |root| {
            var demux: ?*c.GstElement = null;
            chainLock(root);
            if (root.adaptive) demux = ref(firstElem(root).?.element.?);
            chainUnlock(root);
            if (demux) |d| {
                const r = c.gst_element_send_event(d, ev);
                c.gst_object_unref(d);
                return r;
            }
        }
    }
    return c.gst_pad_event_default(pad, parent, ev);
}

fn dpadQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const p = dpad(parent);
    const ch = chainOf(p);
    var ret: c.gboolean = 0;
    chainLock(ch);
    if (p.exposed == 0 and !st(p.bin).shutdown and !ch.deadend and ch.elements != null) {
        const pe = firstElem(ch).?;
        c.g_signal_emit(p.bin, signals[SIG_AUTOPLUG_QUERY], 0, p, pe.element, q, &ret);
    }
    chainUnlock(ch);
    if (ret == 0) ret = c.gst_pad_query_default(pad, parent, q);
    return ret;
}

fn newPad(s: *Self, ch: *Chain) *DPad {
    const tmpl = c.gst_static_pad_template_get(&src_t);
    const p = dpad(c.g_object_new(padType(), "direction", @as(c.gint, c.GST_PAD_SRC), "template", tmpl, N));
    p.chain = ch;
    p.bin = s;
    c.gst_object_unref(tmpl);
    const internal: ?*c.GstPad = @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(p)))));
    c.gst_pad_set_query_function_full(internal, dpadQuery, null, null);
    c.gst_pad_set_event_function_full(padOf(p), dpadEvent, null, null);
    c.gst_object_unref(internal);
    return p;
}

fn freePending(pp: *Pending) void {
    if (pp.probe != 0) c.gst_pad_remove_probe(pp.pad, pp.probe);
    if (pp.caps_id != 0) c.g_signal_handler_disconnect(pp.pad, pp.caps_id);
    c.gst_object_unref(pp.pad);
    A.destroy(pp);
}

fn asyncStart(s: *Self) void {
    st(s).async_pending = true;
    parent_class.?.handle_message.?(binOf(s), c.gst_message_new_async_start(cm.obj(s)));
}

fn asyncDone(s: *Self) void {
    const t = st(s);
    if (!t.async_pending) return;
    parent_class.?.handle_message.?(binOf(s), c.gst_message_new_async_done(cm.obj(s), cm.CLOCK_NONE));
    t.async_pending = false;
}

fn unblockPads(s: *Self) void {
    const t = st(s);
    while (t.blocked_pads != null) {
        const l = t.blocked_pads;
        const p = dpad(l.*.data);
        t.blocked_pads = c.g_list_delete_link(t.blocked_pads, l);
        if (c.gst_ghost_pad_get_target(ghost(p))) |opad| {
            if (p.block_id != 0) {
                c.gst_pad_remove_probe(opad, p.block_id);
                p.block_id = 0;
            }
            c.gst_object_unref(opad);
        }
        p.blocked = 0;
        dynUnlock(s);
        _ = c.gst_pad_set_active(padOf(p), 0);
        dynLock(s);
        c.gst_object_unref(p);
    }
}

fn stopChain(s: *Self, ch: *Chain, out: ?*c.GQueue) void {
    var local: c.GQueue = std.mem.zeroes(c.GQueue);
    const q = out orelse &local;
    chainLock(ch);
    const groups = [_][*c]c.GList{ ch.next_groups, null, ch.old_groups };
    for (groups, 0..) |gl, idx| {
        var l = gl;
        if (idx == 1) {
            if (ch.active_group) |g| stopGroup(s, g, q);
            continue;
        }
        while (l != null) : (l = l.*.next) stopGroup(s, @ptrCast(@alignCast(l.*.data)), q);
    }
    var l = ch.elements;
    while (l != null) : (l = l.*.next) {
        const pe: *Elem = @ptrCast(@alignCast(l.*.data));
        if (pe.capsfilter) |cf| c.g_queue_push_head(q, c.gst_object_ref(cf));
        c.g_queue_push_head(q, c.gst_object_ref(pe.element));
    }
    chainUnlock(ch);
    if (out == null) {
        exposeUnlock(s);
        while (c.g_queue_pop_tail(q)) |x| {
            const e: ?*c.GstElement = @ptrCast(@alignCast(x));
            _ = c.gst_element_set_locked_state(e, 1);
            _ = c.gst_element_set_state(e, c.GST_STATE_NULL);
            c.gst_object_unref(e);
        }
        c.g_queue_clear(q);
        exposeLock(s);
    }
}

fn stopGroup(s: *Self, g: *Group, q: *c.GQueue) void {
    var m = g.children;
    while (m != null) : (m = m.*.next) stopChain(s, @ptrCast(@alignCast(m.*.data)), q);
    if (g.mq) |mq| c.g_queue_push_head(q, c.gst_object_ref(mq));
}

fn flushCleanupGroups(t: *State) void {
    c.g_mutex_lock(&t.cleanup_lock);
    if (t.cleanup_groups != null) {
        _ = freeHidden(t.cleanup_groups);
        t.cleanup_groups = null;
    }
    c.g_mutex_unlock(&t.cleanup_lock);
}

fn changeState(e: [*c]c.GstElement, tr_: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    switch (tr_) {
        c.GST_STATE_CHANGE_NULL_TO_READY => {
            if (t.typefind == null) {
                _ = c.gst_element_post_message(e, c.gst_missing_element_message_new(e, "typefind"));
                cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no typefind!"), FILE, "gst_decode_bin_change_state", 5554);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            exposeLock(s);
            if (t.chain) |root| {
                freeChain(root);
                t.chain = null;
            }
            exposeUnlock(s);
            dynLock(s);
            t.shutdown = false;
            dynUnlock(s);
            t.have_type = false;
            ret = c.GST_STATE_CHANGE_ASYNC;
            asyncStart(s);
            t.have_type_id = c.g_signal_connect_data(t.typefind, "have-type", @ptrCast(&typeFound), s, null, 0);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY, c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (t.have_type_id != 0) c.g_signal_handler_disconnect(t.typefind, t.have_type_id);
            t.have_type_id = 0;
            dynLock(s);
            t.shutdown = true;
            unblockPads(s);
            dynUnlock(s);
            c.g_mutex_lock(&t.cleanup_lock);
            if (t.cleanup_thread) |th| {
                _ = c.g_thread_join(th);
                t.cleanup_thread = null;
            }
            c.g_mutex_unlock(&t.cleanup_lock);
        },
        else => {},
    }
    const bret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, tr_);
    if (bret == c.GST_STATE_CHANGE_FAILURE) {
        asyncDone(s);
        return c.GST_STATE_CHANGE_FAILURE;
    }
    if (bret == c.GST_STATE_CHANGE_NO_PREROLL) {
        asyncDone(s);
        ret = bret;
    }
    switch (tr_) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            asyncDone(s);
            exposeLock(s);
            const root = t.chain;
            if (root) |r| {
                stopChain(s, r, null);
                freeChainInternal(r, true);
                t.chain = null;
            }
            exposeUnlock(s);
            if (root) |r| freeChain(r);
            c.g_list_free_full(t.buffering, @ptrCast(&c.gst_mini_object_unref));
            t.buffering = null;
            flushCleanupGroups(t);
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => flushCleanupGroups(t),
        else => {},
    }
    return ret;
}

fn handleBuffering(s: *Self, msg_in: [*c]c.GstMessage) void {
    const t = st(s);
    var msg = msg_in;
    var smaller_perc: c.gint = 100;
    var smaller: [*c]c.GstMessage = null;
    var found = false;
    c.g_mutex_lock(&t.buffering_lock);
    var msg_perc: c.gint = 0;
    c.gst_message_parse_buffering(msg, &msg_perc);
    c.g_mutex_lock(&t.buffering_post_lock);
    var l = t.buffering;
    while (l != null) {
        var stats: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        if (stats.*.src == msg.*.src) {
            found = true;
            if (msg_perc < 100) {
                c.gst_message_unref(stats);
                l.*.data = c.gst_message_ref(msg);
                stats = msg;
            } else {
                const cur = l;
                l = l.*.next;
                c.gst_message_unref(@ptrCast(@alignCast(cur.*.data)));
                t.buffering = c.g_list_delete_link(t.buffering, cur);
                continue;
            }
        }
        var perc: c.gint = 0;
        c.gst_message_parse_buffering(stats, &perc);
        if (perc < smaller_perc) {
            smaller_perc = perc;
            smaller = stats;
        }
        l = l.*.next;
    }
    if (!found and msg_perc < 100) {
        if (msg_perc < smaller_perc) {
            smaller_perc = msg_perc;
            smaller = msg;
        }
        t.buffering = c.g_list_prepend(t.buffering, c.gst_message_ref(msg));
    }
    if (smaller_perc != 100) _ = c.gst_message_replace(&msg, smaller);
    c.g_mutex_unlock(&t.buffering_lock);
    parent_class.?.handle_message.?(binOf(s), msg);
    c.g_mutex_unlock(&t.buffering_post_lock);
}

fn handleMessage(b: [*c]c.GstBin, msg: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var drop = false;
    if (msg.*.type == c.GST_MESSAGE_ERROR) {
        dynLock(s);
        drop = t.shutdown;
        dynUnlock(s);
        if (!drop) {
            cm.lock(s);
            drop = c.g_list_find(t.filtered, msg.*.src) != null;
            if (drop) t.filtered_errors = c.g_list_prepend(t.filtered_errors, c.gst_message_ref(msg));
            cm.unlock(s);
        }
    } else if (msg.*.type == c.GST_MESSAGE_BUFFERING) {
        handleBuffering(s, msg);
        return;
    }
    if (drop) c.gst_message_unref(msg) else parent_class.?.handle_message.?(b, msg);
}

fn removeElement(b: [*c]c.GstBin, e: [*c]c.GstElement) callconv(.c) c.gboolean {
    const s = me(b);
    const t = st(s);
    var removed = false;
    c.g_mutex_lock(&t.buffering_lock);
    c.g_mutex_lock(&t.buffering_post_lock);
    var l = t.buffering;
    while (l != null) : (l = l.*.next) {
        const stats: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        if (stats.*.src == cm.obj(e) or c.gst_object_has_as_ancestor(stats.*.src, cm.obj(e)) != 0) {
            c.gst_message_unref(stats);
            t.buffering = c.g_list_delete_link(t.buffering, l);
            removed = true;
            break;
        }
    }
    const post = removed and t.buffering == null;
    c.g_mutex_unlock(&t.buffering_lock);
    if (post) _ = c.gst_element_post_message(elem(s), c.gst_message_new_buffering(cm.obj(s), 100));
    c.g_mutex_unlock(&t.buffering_post_lock);
    return parent_class.?.remove_element.?(b, e);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            _ = c.gst_caps_replace(&t.caps, @ptrCast(@alignCast(c.g_value_get_boxed(v))));
            cm.unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            c.g_mutex_lock(&t.subtitle_lock);
            c.g_free(t.encoding);
            t.encoding = c.g_strdup(c.g_value_get_string(v));
            var l = t.subtitles;
            while (l != null) : (l = l.*.next) c.g_object_set(gobj(l.*.data), "subtitle-encoding", t.encoding, N);
            c.g_mutex_unlock(&t.subtitle_lock);
        },
        PROP_SINK_CAPS => c.g_object_set(gobj(t.typefind), "force-caps", c.g_value_get_boxed(v), N),
        PROP_USE_BUFFERING => t.use_buffering = c.g_value_get_boolean(v) != 0,
        PROP_FORCE_SW_DECODERS => t.force_sw = c.g_value_get_boolean(v) != 0,
        PROP_LOW_PERCENT => t.low_percent = c.g_value_get_int(v),
        PROP_HIGH_PERCENT => t.high_percent = c.g_value_get_int(v),
        PROP_MAX_SIZE_BYTES => t.max_bytes = c.g_value_get_uint(v),
        PROP_MAX_SIZE_BUFFERS => t.max_buffers = c.g_value_get_uint(v),
        PROP_MAX_SIZE_TIME => t.max_time = c.g_value_get_uint64(v),
        PROP_POST_STREAM_TOPOLOGY => t.post_topology = c.g_value_get_boolean(v) != 0,
        PROP_EXPOSE_ALL_STREAMS => t.expose_all = c.g_value_get_boolean(v) != 0,
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            t.speed = c.g_value_get_uint64(v) *% 1000;
            cm.unlock(s);
            updateSpeed(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1391),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            const caps = if (t.caps != null) c.gst_caps_ref(t.caps) else null;
            cm.unlock(s);
            c.g_value_take_boxed(v, caps);
        },
        PROP_SUBTITLE_ENCODING => {
            c.g_mutex_lock(&t.subtitle_lock);
            const e = c.g_strdup(t.encoding);
            c.g_mutex_unlock(&t.subtitle_lock);
            c.g_value_take_string(v, e);
        },
        PROP_SINK_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.g_object_get(gobj(t.typefind), "force-caps", &caps, N);
            c.g_value_take_boxed(v, caps);
        },
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, @intFromBool(t.use_buffering)),
        PROP_FORCE_SW_DECODERS => c.g_value_set_boolean(v, @intFromBool(t.force_sw)),
        PROP_LOW_PERCENT => c.g_value_set_int(v, t.low_percent),
        PROP_HIGH_PERCENT => c.g_value_set_int(v, t.high_percent),
        PROP_MAX_SIZE_BYTES => c.g_value_set_uint(v, t.max_bytes),
        PROP_MAX_SIZE_BUFFERS => c.g_value_set_uint(v, t.max_buffers),
        PROP_MAX_SIZE_TIME => c.g_value_set_uint64(v, t.max_time),
        PROP_POST_STREAM_TOPOLOGY => c.g_value_set_boolean(v, @intFromBool(t.post_topology)),
        PROP_EXPOSE_ALL_STREAMS => c.g_value_set_boolean(v, @intFromBool(t.expose_all)),
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            c.g_value_set_uint64(v, t.speed / 1000);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1446),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    if (t.factories != null) c.gst_plugin_feature_list_free(t.factories);
    t.factories = null;
    if (t.chain) |r| freeChain(r);
    t.chain = null;
    if (t.caps != null) c.gst_caps_unref(t.caps);
    t.caps = null;
    c.g_free(t.encoding);
    t.encoding = null;
    c.g_list_free(t.subtitles);
    t.subtitles = null;
    unblockPads(s);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = st(o);
    c.g_mutex_clear(&t.expose_lock);
    c.g_mutex_clear(&t.dyn_lock);
    c.g_mutex_clear(&t.subtitle_lock);
    c.g_mutex_clear(&t.buffering_lock);
    c.g_mutex_clear(&t.buffering_post_lock);
    c.g_mutex_clear(&t.factories_lock);
    c.g_mutex_clear(&t.cleanup_lock);
    A.destroy(t);
    me(o).st = null;
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
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The caps on which to stop decoding.", caps_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINK_CAPS, c.g_param_spec_boxed("sink-caps", "Sink Caps", "The caps of the input data. (NULL = use typefind element)", caps_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_BUFFERING, c.g_param_spec_boolean("use-buffering", "Use Buffering", "Emit GST_MESSAGE_BUFFERING based on low-/high-percent thresholds", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORCE_SW_DECODERS, c.g_param_spec_boolean("force-sw-decoders", "Software Docoders Only", "Use only sofware decoders to process streams", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_LOW_PERCENT, c.g_param_spec_int("low-percent", "Low percent", "Low threshold for buffering to start", 0, 100, 10, cm.RW));
    c.g_object_class_install_property(oc, PROP_HIGH_PERCENT, c.g_param_spec_int("high-percent", "High percent", "High threshold for buffering to finish", 0, 100, 99, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_BYTES, c.g_param_spec_uint("max-size-bytes", "Max. size (bytes)", "Max. amount of bytes in the queue (0=automatic)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_BUFFERS, c.g_param_spec_uint("max-size-buffers", "Max. size (buffers)", "Max. number of buffers in the queue (0=automatic)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MAX_SIZE_TIME, c.g_param_spec_uint64("max-size-time", "Max. size (ns)", "Max. amount of data in the queue (in ns, 0=automatic)", 0, std.math.maxInt(u64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_POST_STREAM_TOPOLOGY, c.g_param_spec_boolean("post-stream-topology", "Post Stream Topology", "Post stream-topology messages", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_EXPOSE_ALL_STREAMS, c.g_param_spec_boolean("expose-all-streams", "Expose All Streams", "Expose all streams, including those of unknown type or that don't match the 'caps' property", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.autoplug_continue = autoplugContinue;
    kc.autoplug_factories = autoplugFactories;
    kc.autoplug_sort = autoplugSort;
    kc.autoplug_select = autoplugSelect;
    kc.autoplug_query = autoplugQuery;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "Decoder Bin", "Generic/Bin/Decoder", "Autoplug and decode to raw media", "Edward Hervey <edward.hervey@collabora.co.uk>, Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    ec.change_state = changeState;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    bc.remove_element = removeElement;
    _ = c.g_type_class_ref(padType());
    c.gst_type_mark_as_plugin_api(flags.selectType(), 0);
    _ = c._gst_debug_category_new("decodebin", 0, "decoder bin");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    c.g_mutex_init(&t.factories_lock);
    t.typefind = c.gst_element_factory_make("typefind", "typefind");
    if (t.typefind == null) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "can't find typefind element, decodebin will not work");
    } else {
        if (c.gst_bin_add(binOf(s), t.typefind) == 0) {
            c.g_log(null, c.G_LOG_LEVEL_WARNING, "Could not add typefind element, decodebin will not work");
            c.gst_object_unref(t.typefind);
            t.typefind = null;
        }
        const pad = c.gst_element_get_static_pad(t.typefind, "sink");
        const tmpl = c.gst_static_pad_template_get(&sink_t);
        const gp = c.gst_ghost_pad_new_from_template("sink", pad, tmpl);
        _ = c.gst_pad_set_active(gp, 1);
        _ = c.gst_element_add_pad(elem(s), gp);
        c.gst_object_unref(tmpl);
        c.gst_object_unref(pad);
    }
    c.g_mutex_init(&t.expose_lock);
    c.g_mutex_init(&t.dyn_lock);
    c.g_mutex_init(&t.subtitle_lock);
    c.g_mutex_init(&t.buffering_lock);
    c.g_mutex_init(&t.buffering_post_lock);
    c.g_mutex_init(&t.cleanup_lock);
    t.caps = utils.rawCaps();
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = dpad(inst);
    p.chain = null;
    p.blocked = 0;
    p.exposed = 0;
    p.drained = 0;
    _ = c.gst_object_ref_sink(p);
}

fn padClassInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return c.g_type_register_static_simple(c.gst_ghost_pad_get_type(), c.g_intern_static_string("GstDecodePad"), @sizeOf(GhostClass), padClassInit, @sizeOf(DPad), padInit, 0);
        }
    }.f);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstDecodeBin", Class, Self, classInit, init);
        }
    }.f);
}
