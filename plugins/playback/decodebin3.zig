const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const utils = @import("utils.zig");

const FILE = "../gst/playback/gstdecodebin3.c";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const GROUP_INVALID: u32 = 0;
const SEQNUM_INVALID: u32 = 0;
const INPUT_KEY = "decodebin.input";

const PROP_CAPS = 1;
const SIG_SELECT_STREAM = 0;
const SIG_ABOUT_TO_FINISH = 1;

const Collection = struct {
    collection: ?*c.GstStreamCollection,
    requested: [*c]c.GList = null,
    to_activate: [*c]c.GList = null,
    seqnum: u32 = SEQNUM_INVALID,
    posted_selected: bool = false,
    all_present: bool = false,
    is_update: bool = false,
};

const Candidate = struct {
    element: ?*c.GstElement,
    err: [*c]c.GstMessage = null,
    latency: [*c]c.GstMessage = null,
};

const Input = struct {
    bin: *Self,
    is_main: bool,
    ghost_sink: ?*c.GstPad = null,
    parsebin_sink: ?*c.GstPad = null,
    collection: ?*c.GstStreamCollection = null,
    upstream_selected: c.gboolean = 0,
    group_id: u32 = GROUP_INVALID,
    parsebin: ?*c.GstElement = null,
    identity: ?*c.GstElement = null,
    added_id: c.gulong = 0,
    removed_id: c.gulong = 0,
    drained_id: c.gulong = 0,
    drained: bool = false,
    is_parsed: bool = false,
    waiting: [*c]c.GList = null,
    probe: c.gulong = 0,
};

const InStream = struct {
    bin: *Self,
    active: ?*c.GstStream,
    input: ?*Input,
    srcpad: ?*c.GstPad,
    event_probe: c.gulong = 0,
    buffer_probe: c.gulong = 0,
    saw_eos: bool = false,
};

const Slot = struct {
    id: c.guint,
    bin: *Self,
    kind: c.GstStreamType,
    input: ?*InStream = null,
    pending: ?*c.GstStream = null,
    active: ?*c.GstStream = null,
    active_id: [*c]const u8 = null,
    sink_pad: ?*c.GstPad = null,
    src_pad: ?*c.GstPad = null,
    probe: c.gulong = 0,
    drop_probe: c.gulong = 0,
    drained: bool = false,
    output: ?*Output = null,
};

const Output = struct {
    bin: *Self,
    kind: c.GstStreamType,
    slot: ?*Slot = null,
    decoder: ?*c.GstElement = null,
    decoder_sink: ?*c.GstPad = null,
    decoder_src: ?*c.GstPad = null,
    linked: bool = false,
    src_pad: ?*c.GstPad = null,
    exposed: bool = false,
    latency: u64 = cm.CLOCK_NONE,
};

pub const Self = extern struct {
    parent: c.GstBin,
    st: ?*State,
};

const State = struct {
    input_lock: c.GMutex = undefined,
    main: ?*Input = null,
    inputs: [*c]c.GList = null,
    input_counter: u32 = 0,
    group_id: u32 = GROUP_INVALID,
    posting: bool = false,
    posting_cond: c.GCond = undefined,
    mq: ?*c.GstElement = null,
    default_interleave: u64 = 0,
    interleave: u64 = 0,
    sel_lock: c.GMutex = undefined,
    in_streams: [*c]c.GList = null,
    outputs: [*c]c.GList = null,
    slots: [*c]c.GList = null,
    slot_id: c.guint = 0,
    collections: [*c]c.GList = null,
    in_col: ?*Collection = null,
    out_col: ?*Collection = null,
    upstream_selects: bool = false,
    fac_lock: c.GMutex = undefined,
    cookie: u32 = 0,
    factories: [*c]c.GList = null,
    decoders: [*c]c.GList = null,
    decodables: [*c]c.GList = null,
    apad: u32 = 0,
    vpad: u32 = 0,
    tpad: u32 = 0,
    mpad: u32 = 0,
    opad: u32 = 0,
    caps: [*c]c.GstCaps = null,
    candidates: [*c]c.GList = null,
};

const Class = extern struct {
    parent: c.GstBinClass,
    select_stream: ?*const fn (?*Self, ?*c.GstStreamCollection, ?*c.GstStream) callconv(.c) c.gint,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var req_sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var video_t = cm.staticTemplate("video_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var audio_t = cm.staticTemplate("audio_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var text_t = cm.staticTemplate("text_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var meta_t = cm.staticTemplate("metadata_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var signals: [2]c.guint = .{ 0, 0 };
var once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn st(p: anytype) *State {
    return me(p).st.?;
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

fn ghost(p: ?*c.GstPad) ?*c.GstGhostPad {
    return @ptrCast(@alignCast(p));
}

fn ref(p: anytype) @TypeOf(p) {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn selLock(s: *Self) void {
    c.g_mutex_lock(&st(s).sel_lock);
}

fn selUnlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).sel_lock);
}

fn inLock(s: *Self) void {
    c.g_mutex_lock(&st(s).input_lock);
}

fn inUnlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).input_lock);
}

fn streamError(s: *Self, dbg: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FAILED, null, c.g_strdup(dbg), FILE, func, line);
}

fn intAccu(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const v = c.g_value_get_int(ret);
    c.g_value_set_int(accu, v);
    return @intFromBool(v == -1);
}

fn defaultSelect(_: ?*Self, _: ?*c.GstStreamCollection, _: ?*c.GstStream) callconv(.c) c.gint {
    return -1;
}

fn listIter(comptime T: type, l: [*c]c.GList) Iter(T) {
    return .{ .l = l };
}

fn Iter(comptime T: type) type {
    return struct {
        l: [*c]c.GList,
        fn next(it: *@This()) ?*T {
            const cur = it.l;
            if (cur == null) return null;
            it.l = cur.*.next;
            return @ptrCast(@alignCast(cur.*.data));
        }
    };
}

fn updateFactories(s: *Self) void {
    const t = st(s);
    const cookie = c.gst_registry_get_feature_list_cookie(c.gst_registry_get());
    if (t.factories != null and t.cookie == cookie) return;
    if (t.factories != null) c.gst_plugin_feature_list_free(t.factories);
    if (t.decoders != null) c.g_list_free(t.decoders);
    if (t.decodables != null) c.g_list_free(t.decodables);
    t.factories = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODABLE, c.GST_RANK_MARGINAL);
    t.factories = c.g_list_sort(t.factories, c.gst_plugin_feature_rank_compare_func);
    t.cookie = cookie;
    t.decoders = null;
    t.decodables = null;
    var l = t.factories;
    while (l != null) : (l = l.*.next) {
        const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        if (c.gst_element_factory_list_is_type(f, c.GST_ELEMENT_FACTORY_TYPE_DECODER) != 0) {
            t.decoders = c.g_list_append(t.decoders, f);
        } else t.decodables = c.g_list_append(t.decodables, f);
    }
}

fn sinkTemplates(f: ?*c.GstElementFactory) Iter(c.GstStaticPadTemplate) {
    return .{ .l = @constCast(c.gst_element_factory_get_static_pad_templates(f)) };
}

fn parserCapsFilter(s: *Self, caps: [*c]c.GstCaps) [*c]c.GstCaps {
    if (caps == null or c.gst_caps_is_any(caps) != 0) return c.gst_caps_new_any();
    const t = st(s);
    var filter = c.gst_caps_new_empty();
    c.g_mutex_lock(&t.fac_lock);
    updateFactories(s);
    var l = t.decoders;
    while (l != null) : (l = l.*.next) {
        var it = sinkTemplates(@ptrCast(@alignCast(l.*.data)));
        while (it.next()) |tp| {
            if (tp.direction != c.GST_PAD_SINK or tp.presence != c.GST_PAD_ALWAYS) continue;
            const tc = c.gst_static_pad_template_get_caps(tp);
            filter = c.gst_caps_merge(filter, c.gst_caps_intersect_full(tc, caps, c.GST_CAPS_INTERSECT_FIRST));
            c.gst_caps_unref(tc);
        }
    }
    c.g_mutex_unlock(&t.fac_lock);
    return filter;
}

fn checkParserCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    const raw = utils.rawCaps();
    const ok = c.gst_caps_can_intersect(caps, raw) != 0;
    c.gst_caps_unref(raw);
    if (ok) return true;
    const t = st(s);
    c.g_mutex_lock(&t.fac_lock);
    defer c.g_mutex_unlock(&t.fac_lock);
    updateFactories(s);
    var l = t.decoders;
    while (l != null) : (l = l.*.next) {
        var it = sinkTemplates(@ptrCast(@alignCast(l.*.data)));
        while (it.next()) |tp| {
            if (tp.direction != c.GST_PAD_SINK or tp.presence != c.GST_PAD_ALWAYS) continue;
            const tc = c.gst_static_pad_template_get_caps(tp);
            const hit = c.gst_caps_can_intersect(tc, caps) != 0;
            c.gst_caps_unref(tc);
            if (hit) return true;
        }
    }
    return false;
}

fn inStreamProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const in: *InStream = @ptrCast(@alignCast(data));
    const s = in.bin;
    if (cm.isEvent(info.*.data)) {
        var ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
        switch (cm.eventType(ev)) {
            c.GST_EVENT_STREAM_START => {
                var gid: c.guint = GROUP_INVALID;
                if (c.gst_event_parse_group_id(ev, &gid) == 0) gid = c.gst_util_group_id_next();
                if (setGroupId(in.input.?, &gid)) {
                    ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
                    c.gst_event_set_group_id(ev, gid);
                    info.*.data = ev;
                }
                in.saw_eos = false;
                var stream: ?*c.GstStream = null;
                c.gst_event_parse_stream(ev, &stream);
                if (stream) |x| {
                    if (in.active != x) {
                        if (in.active) |old| c.gst_object_unref(old);
                        in.active = x;
                        selLock(s);
                        linkToSlot(in);
                        selUnlock(s);
                    } else c.gst_object_unref(x);
                }
            },
            c.GST_EVENT_GAP => {
                if (in.buffer_probe != 0) unblockStreams(in.input.?, true);
            },
            c.GST_EVENT_CAPS => {
                var caps: [*c]c.GstCaps = null;
                c.gst_event_parse_caps(ev, &caps);
                if (caps != null and in.active != null) c.gst_stream_set_caps(in.active, caps);
            },
            c.GST_EVENT_TAG => {
                var tags: ?*c.GstTagList = null;
                c.gst_event_parse_tag(ev, &tags);
                if (tags != null and c.gst_tag_list_get_scope(tags) == c.GST_TAG_SCOPE_STREAM and in.active != null) c.gst_stream_set_tags(in.active, tags);
            },
            c.GST_EVENT_EOS => in.saw_eos = true,
            c.GST_EVENT_FLUSH_STOP => in.saw_eos = false,
            else => {},
        }
    } else if (cm.isQuery(info.*.data)) {
        if (in.input != null and in.input.?.identity != null) return c.GST_PAD_PROBE_OK;
        const q: ?*c.GstQuery = @ptrCast(@alignCast(info.*.data));
        if (cm.queryType(q) == c.GST_QUERY_CAPS and (info.*.type & c.GST_PAD_PROBE_TYPE_PULL) != 0) {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const allowed = parserCapsFilter(s, filter);
            c.gst_query_set_caps_result(q, allowed);
            c.gst_caps_unref(allowed);
            return c.GST_PAD_PROBE_HANDLED;
        } else if (cm.queryType(q) == c.GST_QUERY_ACCEPT_CAPS) {
            var prop: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &prop);
            if (c.gst_caps_can_intersect(prop, st(s).caps) != 0) {
                c.gst_query_set_accept_caps_result(q, 1);
            } else c.gst_query_set_accept_caps_result(q, @intFromBool(checkParserCaps(s, prop)));
            return c.GST_PAD_PROBE_HANDLED;
        }
    }
    return c.GST_PAD_PROBE_OK;
}

fn inBufferProbe(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    unblockStreams(@ptrCast(@alignCast(data)), true);
    return c.GST_PAD_PROBE_OK;
}

fn addStream(input: *Input, pad: ?*c.GstPad, stream: ?*c.GstStream) *InStream {
    const s = input.bin;
    const r = A.create(InStream) catch @panic("oom");
    r.* = .{ .bin = s, .active = stream, .input = input, .srcpad = ref(pad.?) };
    r.event_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH, inStreamProbe, r, null);
    r.buffer_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BLOCK | c.GST_PAD_PROBE_TYPE_BUFFER, inBufferProbe, input, null);
    selLock(s);
    st(s).in_streams = c.g_list_append(st(s).in_streams, r);
    selUnlock(s);
    return r;
}

fn removeInStream(s: *Self, in: *InStream) void {
    _ = c.gst_object_replace(@ptrCast(&in.active), null);
    if (in.srcpad) |p| {
        if (c.gst_pad_get_peer(p)) |peer| {
            _ = c.gst_pad_unlink(p, peer);
            c.gst_object_unref(peer);
        }
        if (in.buffer_probe != 0) c.gst_pad_remove_probe(p, in.buffer_probe);
        if (in.event_probe != 0) c.gst_pad_remove_probe(p, in.event_probe);
        c.gst_object_unref(p);
    }
    if (slotForInput(s, in)) |slot| {
        slot.pending = null;
        slot.input = null;
    }
    st(s).in_streams = c.g_list_remove(st(s).in_streams, in);
    A.destroy(in);
}

fn unblockStreams(input: *Input, others: bool) void {
    const s = input.bin;
    const t = st(s);
    var unused: [*c]c.GList = null;
    selLock(s);
    var l = t.in_streams;
    while (l != null) {
        const in: *InStream = @ptrCast(@alignCast(l.*.data));
        const nx = l.*.next;
        if (in.input != input) {
            l = nx;
            continue;
        }
        if (in.active == null) in.active = c.gst_pad_get_stream(in.srcpad);
        linkToSlot(in);
        if (in.buffer_probe != 0) {
            c.gst_pad_remove_probe(in.srcpad, in.buffer_probe);
            in.buffer_probe = 0;
        }
        if (in.saw_eos) {
            removeInStream(s, in);
            l = t.in_streams;
        } else l = nx;
    }
    var it = listIter(Slot, t.slots);
    while (it.next()) |slot| {
        if (slot.input == null) unused = c.g_list_append(unused, c.gst_object_ref(slot.sink_pad));
    }
    selUnlock(s);
    var u = unused;
    while (u != null) : (u = u.*.next) _ = c.gst_pad_send_event(@ptrCast(@alignCast(u.*.data)), c.gst_event_new_eos());
    c.g_list_free_full(unused, c.gst_object_unref);
    if (others) {
        var ii = listIter(Input, t.inputs);
        while (ii.next()) |o| {
            if (o.collection == input.collection) unblockStreams(o, false);
        }
    }
}

fn parsebinPadAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    _ = addStream(@ptrCast(@alignCast(data)), pad, null);
}

fn streamForPad(s: *Self, pad: ?*c.GstPad) ?*InStream {
    var it = listIter(InStream, st(s).in_streams);
    while (it.next()) |x| if (x.srcpad == pad) return x;
    return null;
}

fn updateInterleave(s: *Self) void {
    const t = st(s);
    var max: u64 = cm.CLOCK_NONE;
    var it = listIter(Output, t.outputs);
    while (it.next()) |o| {
        if (o.latency != cm.CLOCK_NONE and (max == cm.CLOCK_NONE or o.latency > max)) max = o.latency;
    }
    if (max == cm.CLOCK_NONE) return;
    max += 100 * c.GST_MSECOND;
    if (max == t.interleave) return;
    t.interleave = max;
    c.g_object_set(gobj(t.mq), "min-interleave-time", t.interleave, N);
}

fn slotFreeAsync(o: ?*c.GstObject, data: c.gpointer) callconv(.c) void {
    freeSlot(me(o), @ptrCast(@alignCast(data)));
}

fn removeSlotStreaming(s: *Self, slot: *Slot) void {
    const t = st(s);
    if (slot.output) |o| {
        t.outputs = c.g_list_remove(t.outputs, o);
        freeOutput(o);
    }
    if (slot.probe != 0) c.gst_pad_remove_probe(slot.src_pad, slot.probe);
    slot.probe = 0;
    t.slots = c.g_list_remove(t.slots, slot);
    updateInterleave(s);
    c.gst_object_call_async(cm.obj(s), slotFreeAsync, slot);
}

fn parsebinPadRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) != c.GST_PAD_SRC) return;
    const inp: *Input = @ptrCast(@alignCast(data));
    const s = inp.bin;
    selLock(s);
    defer selUnlock(s);
    const in = streamForPad(s, pad) orelse return;
    const slot = slotForInput(s, in);
    removeInStream(s, in);
    if (slot) |x| if (x.drained) removeSlotStreaming(s, x);
}

fn parsebinContinue(_: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) c.gboolean {
    return @intFromBool(c.gst_caps_can_intersect(caps, st(data).caps) == 0);
}

fn setGroupId(input: *Input, gid: *c.guint) bool {
    const t = st(input.bin);
    if (input.group_id != gid.*) input.group_id = gid.*;
    if (gid.* != t.group_id) {
        if (t.group_id == GROUP_INVALID) t.group_id = gid.*;
        gid.* = t.group_id;
        return true;
    }
    return false;
}

fn parsebinDrained(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const input: *Input = @ptrCast(@alignCast(data));
    const s = input.bin;
    input.drained = true;
    var all = true;
    var it = listIter(Input, st(s).inputs);
    while (it.next()) |x| all = all and x.drained;
    if (all) c.g_signal_emit(s, signals[SIG_ABOUT_TO_FINISH], 0);
}

fn stateLock(e: ?*c.GstElement) void {
    c.g_rec_mutex_lock(&e.?.state_lock);
}

fn stateUnlock(e: ?*c.GstElement) void {
    c.g_rec_mutex_unlock(&e.?.state_lock);
}

fn ensureParsebin(input: *Input) bool {
    const s = input.bin;
    if (input.parsebin == null) {
        const pb = c.gst_element_factory_make("parsebin", null) orelse {
            _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), "parsebin"));
            return false;
        };
        input.parsebin = ref(pb);
        input.parsebin_sink = c.gst_element_get_static_pad(pb, "sink");
        input.added_id = c.g_signal_connect_data(pb, "pad-added", @ptrCast(&parsebinPadAdded), input, null, 0);
        input.removed_id = c.g_signal_connect_data(pb, "pad-removed", @ptrCast(&parsebinPadRemoved), input, null, 0);
        input.drained_id = c.g_signal_connect_data(pb, "drained", @ptrCast(&parsebinDrained), input, null, 0);
        _ = c.g_signal_connect_data(pb, "autoplug-continue", @ptrCast(&parsebinContinue), s, null, 0);
    }
    var set_state = false;
    if (cm.obj(input.parsebin).parent != cm.obj(s)) {
        stateLock(input.parsebin);
        _ = c.gst_bin_add(binOf(s), input.parsebin);
        set_state = true;
    }
    _ = c.gst_ghost_pad_set_target(ghost(input.ghost_sink), input.parsebin_sink);
    if (set_state) {
        _ = c.gst_element_sync_state_with_parent(input.parsebin);
        stateUnlock(input.parsebin);
    }
    return true;
}

fn inputBufferProbe(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const input: *Input = @ptrCast(@alignCast(data));
    inLock(input.bin);
    if (input.parsebin == null and input.identity == null) _ = ensureParsebin(input);
    input.probe = 0;
    inUnlock(input.bin);
    return c.GST_PAD_PROBE_REMOVE;
}

fn inputOf(pad: ?*c.GstPad) ?*Input {
    return @ptrCast(@alignCast(c.g_object_get_data(gobj(pad), INPUT_KEY)));
}

fn inputLink(pad: ?*c.GstPad, parent: ?*c.GstObject, peer: ?*c.GstPad) callconv(.c) c.GstPadLinkReturn {
    const s = me(parent);
    const t = st(s);
    const input = inputOf(pad) orelse {
        _ = cm.that(false, "gst_decodebin3_input_pad_link", "input");
        return c.GST_PAD_LINK_REFUSED;
    };
    const q = c.gst_query_new_scheduling();
    const pull = c.gst_pad_query(peer, q) != 0 and c.gst_query_has_scheduling_mode_with_flags(q, c.GST_PAD_MODE_PULL, c.GST_SCHEDULING_FLAG_SEEKABLE) != 0;
    c.gst_query_unref(q);
    var res: c.GstPadLinkReturn = c.GST_PAD_LINK_OK;
    inLock(s);
    if (input.is_main and c.g_list_find(t.inputs, input) == null) t.inputs = c.g_list_prepend(t.inputs, input);
    if (pull) {
        if (!ensureParsebin(input)) {
            res = c.GST_PAD_LINK_REFUSED;
        } else if (input.identity != null) res = c.GST_PAD_LINK_REFUSED;
    } else if (input.probe == 0) {
        input.probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BUFFER, inputBufferProbe, input, null);
    }
    if (input.collection) |col| {
        c.gst_object_unref(col);
        input.collection = null;
    }
    inUnlock(s);
    return res;
}

fn durationDrop(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (cm.isQuery(info.*.data) and cm.queryType(info.*.data) == c.GST_QUERY_DURATION) return c.GST_PAD_PROBE_HANDLED;
    return c.GST_PAD_PROBE_OK;
}

fn recalcGroupId(s: *Self) void {
    const t = st(s);
    var common: u32 = GROUP_INVALID;
    var it = listIter(Input, t.inputs);
    while (it.next()) |x| {
        if (x.group_id != common) {
            if (common != GROUP_INVALID) return;
            common = x.group_id;
        }
    }
    if (common != t.group_id) t.group_id = common;
}

fn resetParsebin(s: *Self, input: *Input) void {
    if (input.parsebin == null) return;
    stateLock(elem(s));
    _ = c.gst_element_set_state(input.parsebin, c.GST_STATE_NULL);
    input.drained = false;
    input.group_id = GROUP_INVALID;
    recalcGroupId(s);
    var it = listIter(InStream, st(s).in_streams);
    while (it.next()) |x| if (x.input == input) {
        x.saw_eos = true;
    };
    _ = c.gst_element_sync_state_with_parent(input.parsebin);
    stateUnlock(elem(s));
}

fn inputUnlink(pad: ?*c.GstPad, _: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const input: *Input = @ptrCast(@alignCast(data));
    const s = input.bin;
    inLock(s);
    if (input.parsebin != null and cm.pad(pad).mode == c.GST_PAD_MODE_PULL) resetParsebin(s, input);
    c.g_list_free_full(input.waiting, cm.unrefEvent);
    input.waiting = null;
    input.group_id = GROUP_INVALID;
    input.drained = false;
    recalcGroupId(s);
    inUnlock(s);
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(e);
    const t = st(s);
    const input = inputOf(pad) orelse {
        _ = cm.that(false, "gst_decodebin3_release_pad", "input");
        return;
    };
    inLock(s);
    if (input.collection) |col| {
        c.gst_object_unref(col);
        input.collection = null;
    }
    const msg = handleCollectionLocked(s, null, input);
    if (msg != null) {
        var probe: c.gulong = 0;
        if (input.parsebin != null) probe = c.gst_pad_add_probe(input.parsebin_sink, c.GST_PAD_PROBE_TYPE_QUERY_UPSTREAM, durationDrop, input, null);
        _ = c.gst_element_post_message(elem(s), msg);
        if (input.parsebin != null) c.gst_pad_remove_probe(input.parsebin_sink, probe);
    }
    if (!input.is_main) {
        t.inputs = c.g_list_remove(t.inputs, input);
        freeInput(input);
    } else resetInput(input);
    inUnlock(s);
}

fn resetInput(input: *Input) void {
    const s = input.bin;
    _ = c.gst_ghost_pad_set_target(ghost(input.ghost_sink), null);
    if (input.parsebin) |pb| {
        c.g_signal_handler_disconnect(pb, input.removed_id);
        c.g_signal_handler_disconnect(pb, input.added_id);
        c.g_signal_handler_disconnect(pb, input.drained_id);
        _ = c.gst_element_set_state(pb, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), pb);
        c.gst_object_unref(pb);
        input.parsebin = null;
        if (input.parsebin_sink) |p| c.gst_object_unref(p);
        input.parsebin_sink = null;
    }
    if (input.identity) |id| {
        const idpad = c.gst_element_get_static_pad(id, "src");
        selLock(s);
        if (streamForPad(s, idpad)) |x| removeInStream(s, x);
        selUnlock(s);
        c.gst_object_unref(idpad);
        _ = c.gst_element_set_state(id, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), id);
        c.gst_object_unref(id);
        input.identity = null;
    }
    if (input.collection) |col| c.gst_object_unref(col);
    input.collection = null;
    if (input.probe != 0) {
        c.gst_pad_remove_probe(input.ghost_sink, input.probe);
        input.probe = 0;
    }
    c.g_list_free_full(input.waiting, cm.unrefEvent);
    input.waiting = null;
    input.group_id = GROUP_INVALID;
}

fn freeInput(input: *Input) void {
    const s = input.bin;
    resetInput(input);
    inUnlock(s);
    _ = c.gst_element_remove_pad(elem(s), input.ghost_sink);
    inLock(s);
    A.destroy(input);
}

fn sinkQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (inputOf(pad) == null) {
        _ = cm.that(false, "sink_query_function", "input");
        return 0;
    }
    if (cm.queryType(q) == c.GST_QUERY_ACCEPT_CAPS) {
        c.gst_query_set_accept_caps_result(q, 1);
        return 1;
    }
    return c.gst_pad_query_default(pad, parent, q);
}

fn requiresParsebin(input: *Input, caps: [*c]c.GstCaps) bool {
    const stream = c.gst_pad_get_stream(input.ghost_sink);
    defer if (stream) |x| c.gst_object_unref(x);
    if (stream == null) return true;
    if (c.gst_caps_can_intersect(caps, st(input.bin).caps) != 0) return false;
    if (input.is_parsed) return false;
    return true;
}

fn setupIdentity(input: *Input) void {
    const s = input.bin;
    const id = c.gst_element_factory_make("identity", null);
    c.g_object_set(gobj(id), "drop-allocation", @as(c.gboolean, 1), N);
    input.identity = ref(id.?);
    const idsink = c.gst_element_get_static_pad(id, "sink");
    const idsrc = c.gst_element_get_static_pad(id, "src");
    _ = c.gst_bin_add(binOf(s), id);
    _ = addStream(input, idsrc, c.gst_pad_get_stream(input.ghost_sink));
    c.gst_object_unref(idsrc);
    c.gst_object_unref(idsink);
    _ = c.gst_ghost_pad_set_target(ghost(input.ghost_sink), idsink);
    _ = c.gst_element_sync_state_with_parent(id);
}

fn sinkEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev_in: ?*c.GstEvent) callconv(.c) c.gboolean {
    const s = me(parent);
    const t = st(s);
    var ev = ev_in;
    const input = inputOf(pad) orelse {
        _ = cm.that(false, "sink_event_function", "input");
        return 0;
    };
    switch (cm.eventType(ev)) {
        c.GST_EVENT_STREAM_START => {
            const q = c.gst_query_new_selectable();
            var sct = c.gst_event_get_structure(ev);
            if (c.gst_pad_peer_query(pad, q) != 0) {
                c.gst_query_parse_selectable(q, &input.upstream_selected);
            } else input.upstream_selected = 0;
            c.gst_query_unref(q);
            inLock(s);
            if (input.upstream_selected != 0) t.upstream_selects = true;
            input.is_parsed = sct != null and c.gst_structure_has_field(sct, "urisourcebin-parsed-data") != 0;
            if (input.is_parsed) {
                ev = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev)));
                sct = c.gst_event_get_structure(ev);
                c.gst_structure_remove_field(@constCast(sct), "urisourcebin-parsed-data");
            }
            input.group_id = GROUP_INVALID;
            recalcGroupId(s);
            var stream: ?*c.GstStream = null;
            c.gst_event_parse_stream(ev, &stream);
            if (stream) |x| {
                const sid = c.gst_stream_get_stream_id(x);
                if (t.in_col != null and t.in_col.?.collection != null and inCollection(t.in_col.?.collection, sid) == null) {
                    const msg = handleCollectionLocked(s, null, input);
                    if (msg != null) {
                        inUnlock(s);
                        _ = c.gst_element_post_message(elem(s), msg);
                        inLock(s);
                    }
                }
                c.gst_object_unref(x);
            }
            inUnlock(s);
        },
        c.GST_EVENT_STREAM_COLLECTION => {
            var col: ?*c.GstStreamCollection = null;
            c.gst_event_parse_stream_collection(ev, &col);
            if (col) |x| {
                inLock(s);
                while (t.posting) c.g_cond_wait(&t.posting_cond, &t.input_lock);
                const msg = handleCollectionLocked(s, x, input);
                c.gst_object_unref(x);
                if (msg != null) {
                    t.posting = true;
                    inUnlock(s);
                    _ = c.gst_element_post_message(elem(s), msg);
                    inLock(s);
                    t.posting = false;
                    c.g_cond_broadcast(&t.posting_cond);
                }
                inUnlock(s);
            }
            if (input.parsebin == null and input.identity == null) setupIdentity(input);
            if (input.probe != 0) {
                c.gst_pad_remove_probe(pad, input.probe);
                input.probe = 0;
            }
            if (input.waiting != null) {
                var l = input.waiting;
                while (l != null) : (l = l.*.next) _ = c.gst_pad_event_default(pad, cm.obj(s), @ptrCast(@alignCast(l.*.data)));
                c.g_list_free(input.waiting);
                input.waiting = null;
            }
        },
        c.GST_EVENT_CAPS => caps: {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            if (caps == null) break :caps;
            if (input.probe != 0) {
                c.gst_pad_remove_probe(pad, input.probe);
                input.probe = 0;
            }
            if (input.parsebin == null and input.identity == null) {
                if (requiresParsebin(input, caps)) {
                    inLock(s);
                    _ = ensureParsebin(input);
                    inUnlock(s);
                }
                break :caps;
            }
            if (input.identity != null) {
                if (requiresParsebin(input, caps)) {
                    c.gst_event_unref(ev);
                    return 0;
                }
                break :caps;
            }
            if (c.gst_pad_query_accept_caps(input.parsebin_sink, caps) == 0) {
                inLock(s);
                resetParsebin(s, input);
                inUnlock(s);
            }
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(ev, &seg);
            if (seg != null and seg.*.format != c.GST_FORMAT_TIME and input.parsebin == null) {
                inLock(s);
                _ = ensureParsebin(input);
                inUnlock(s);
            }
        },
        else => {},
    }
    if (input.is_parsed) {
        inLock(s);
        while (t.posting) c.g_cond_wait(&t.posting_cond, &t.input_lock);
        const have = input.collection != null;
        inUnlock(s);
        if (!have) {
            input.waiting = c.g_list_append(input.waiting, ev);
            return 1;
        }
    }
    return c.gst_pad_event_default(pad, cm.obj(s), ev);
}

fn newInput(s: *Self, main: bool) *Input {
    const t = st(s);
    const input = A.create(Input) catch @panic("oom");
    input.* = .{ .bin = s, .is_main = main };
    if (main) {
        input.ghost_sink = c.gst_ghost_pad_new_no_target("sink", c.GST_PAD_SINK);
    } else {
        const name = c.g_strdup_printf("sink_%u", t.input_counter);
        t.input_counter += 1;
        input.ghost_sink = c.gst_ghost_pad_new_no_target(name, c.GST_PAD_SINK);
        c.g_free(name);
    }
    c.g_object_set_data(gobj(input.ghost_sink), INPUT_KEY, input);
    c.gst_pad_set_event_function_full(input.ghost_sink, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(input.ghost_sink, sinkQuery, null, null);
    c.gst_pad_set_link_function_full(input.ghost_sink, inputLink, null, null);
    _ = c.g_signal_connect_data(input.ghost_sink, "unlinked", @ptrCast(&inputUnlink), input, null, 0);
    _ = c.gst_pad_set_active(input.ghost_sink, 1);
    _ = c.gst_element_add_pad(elem(s), input.ghost_sink);
    return input;
}

fn requestNewPad(e: [*c]c.GstElement, _: [*c]c.GstPadTemplate, _: [*c]const c.gchar, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(e);
    const input = newInput(s, false);
    inLock(s);
    st(s).inputs = c.g_list_append(st(s).inputs, input);
    inUnlock(s);
    return input.ghost_sink;
}

fn inList(list: [*c]c.GList, sid: [*c]const u8) [*c]const u8 {
    var l = list;
    while (l != null) : (l = l.*.next) {
        const o: [*c]const u8 = @ptrCast(l.*.data);
        if (c.g_strcmp0(sid, o) == 0) return o;
    }
    return null;
}

fn removeFromList(list: [*c]c.GList, sid: [*c]const u8) [*c]c.GList {
    var l = list;
    while (l != null) : (l = l.*.next) {
        if (c.g_strcmp0(sid, @ptrCast(l.*.data)) == 0) {
            c.g_free(l.*.data);
            return c.g_list_delete_link(list, l);
        }
    }
    return list;
}

fn isActive(s: *Self, sid: [*c]const u8) bool {
    var it = listIter(Slot, st(s).slots);
    while (it.next()) |x| if (x.output != null and c.g_strcmp0(sid, x.active_id) == 0) return true;
    return false;
}

fn isRequested(s: *Self, sid: [*c]const u8) bool {
    const col = st(s).out_col orelse return false;
    return inList(col.requested, sid) != null;
}

fn updateRequested(s: *Self, col: *Collection) void {
    if (col.requested != null) return;
    const n = c.gst_stream_collection_get_size(col.collection);
    var tmp: [*c]c.GList = null;
    var all_user = true;
    var used: c.GstStreamType = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const stream = c.gst_stream_collection_get_stream(col.collection, i);
        const sid = c.gst_stream_get_stream_id(stream);
        var req: c.gint = -1;
        c.g_signal_emit(s, signals[SIG_SELECT_STREAM], 0, col.collection, stream, &req);
        if (req == -1) all_user = false;
        if (req == 1 or (req == -1 and (isRequested(s, sid) or isActive(s, sid)))) {
            tmp = c.g_list_append(tmp, @constCast(sid));
            used |= c.gst_stream_get_stream_type(stream);
        }
    }
    if (!all_user and col.seqnum == SEQNUM_INVALID) {
        i = 0;
        while (i < n) : (i += 1) {
            const stream = c.gst_stream_collection_get_stream(col.collection, i);
            const kind = c.gst_stream_get_stream_type(stream);
            if (kind != c.GST_STREAM_TYPE_UNKNOWN and (used & kind) == 0) {
                tmp = c.g_list_append(tmp, @constCast(c.gst_stream_get_stream_id(stream)));
                used |= kind;
            }
        }
    }
    if (tmp != null) {
        col.requested = c.g_list_copy_deep(tmp, @ptrCast(&c.g_strdup), null);
        col.posted_selected = false;
        c.g_list_free(tmp);
    }
}

fn sortStreams(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const sa: ?*c.GstStream = @ptrCast(@alignCast(@constCast(a)));
    const sb: ?*c.GstStream = @ptrCast(@alignCast(@constCast(b)));
    const ta = c.gst_stream_get_stream_type(sa);
    const tb = c.gst_stream_get_stream_type(sb);
    if (ta != tb) {
        var r: c.gint = 1;
        if ((ta & c.GST_STREAM_TYPE_VIDEO) != 0) {
            r = -1;
        } else if ((ta & c.GST_STREAM_TYPE_AUDIO) != 0) {
            r = if ((tb & c.GST_STREAM_TYPE_VIDEO) == 0) -1 else 1;
        } else if ((ta & c.GST_STREAM_TYPE_TEXT) != 0) {
            r = if ((tb & c.GST_STREAM_TYPE_VIDEO) == 0 and (tb & c.GST_STREAM_TYPE_AUDIO) == 0) -1 else 1;
        } else if ((ta & c.GST_STREAM_TYPE_CONTAINER) != 0) {
            r = if ((tb & c.GST_STREAM_TYPE_UNKNOWN) != 0) -1 else 1;
        }
        return r;
    }
    const fa = c.gst_stream_get_stream_flags(sa) & c.GST_STREAM_FLAG_SELECT;
    const fb = c.gst_stream_get_stream_flags(sb) & c.GST_STREAM_FLAG_SELECT;
    if (fa != 0 and fb == 0) return -1;
    if (fa == 0 and fb != 0) return 1;
    return c.g_strcmp0(c.gst_stream_get_stream_id(sa), c.gst_stream_get_stream_id(sb));
}

fn mergedCollection(s: *Self) ?*c.GstStreamCollection {
    const t = st(s);
    var res: ?*c.GstStreamCollection = null;
    var merge = false;
    var it = listIter(Input, t.inputs);
    while (it.next()) |x| {
        if (x.collection != null and x.collection != res) {
            if (res != null) {
                merge = true;
                break;
            }
            res = x.collection;
        }
    }
    if (!merge) return if (res) |r| ref(r) else null;
    const out = c.gst_stream_collection_new("decodebin3");
    var streams: [*c]c.GList = null;
    it = listIter(Input, t.inputs);
    while (it.next()) |x| {
        const col = x.collection orelse continue;
        var i: c.guint = 0;
        while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
            const stream = c.gst_stream_collection_get_stream(col, i);
            if (!utils.streamInList(streams, stream)) streams = c.g_list_append(streams, stream);
        }
    }
    streams = c.g_list_sort(streams, sortStreams);
    var l = streams;
    while (l != null) : (l = l.*.next) _ = c.gst_stream_collection_add_stream(out, @ptrCast(@alignCast(c.gst_object_ref(l.*.data))));
    c.g_list_free(streams);
    return out;
}

fn inputForChild(s: *Self, child: ?*c.GstObject) ?*Input {
    var found: ?*Input = null;
    var p: ?*c.GstObject = @ptrCast(@alignCast(c.gst_object_ref(child)));
    while (true) {
        var it = listIter(Input, st(s).inputs);
        while (it.next()) |x| {
            if (x.parsebin != null and p == cm.obj(x.parsebin)) {
                found = x;
                break;
            }
        }
        const nx = c.gst_object_get_parent(p);
        c.gst_object_unref(p);
        p = nx;
        if (p == null or p == cm.obj(s)) break;
    }
    if (p) |x| c.gst_object_unref(x);
    return found;
}

fn inCollection(col: ?*c.GstStreamCollection, sid: [*c]const u8) [*c]const u8 {
    if (col == null) return null;
    var i: c.guint = 0;
    while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
        const o = c.gst_stream_get_stream_id(c.gst_stream_collection_get_stream(col, i));
        if (c.g_strcmp0(sid, o) == 0) return o;
    }
    return null;
}

fn collectionForStream(s: *Self, sid: [*c]const u8) ?*Collection {
    var it = listIter(Collection, st(s).collections);
    while (it.next()) |x| if (inCollection(x.collection, sid) != null) return x;
    return null;
}

fn allInCollection(col: ?*c.GstStreamCollection, streams: [*c]c.GList) bool {
    var l = streams;
    while (l != null) : (l = l.*.next) if (inCollection(col, @ptrCast(l.*.data)) == null) return false;
    return true;
}

fn freeCollection(col: *Collection) void {
    c.gst_object_unref(col.collection);
    c.g_list_free_full(col.requested, c.g_free);
    c.g_list_free(col.to_activate);
    A.destroy(col);
}

fn newCollection(col: ?*c.GstStreamCollection) *Collection {
    const x = A.create(Collection) catch @panic("oom");
    x.* = .{ .collection = col };
    return x;
}

fn identical(a: ?*c.GstStreamCollection, b: ?*c.GstStreamCollection) bool {
    if (a == b) return true;
    if (c.gst_stream_collection_get_size(a) != c.gst_stream_collection_get_size(b)) return false;
    var i: c.guint = 0;
    while (i < c.gst_stream_collection_get_size(b)) : (i += 1) {
        if (inCollection(a, c.gst_stream_get_stream_id(c.gst_stream_collection_get_stream(b, i))) == null) return false;
    }
    return true;
}

fn handleCollectionLocked(s: *Self, col_in: ?*c.GstStreamCollection, input: ?*Input) [*c]c.GstMessage {
    const t = st(s);
    const inp = input orelse return null;
    _ = c.gst_object_replace(@ptrCast(&inp.collection), cm.obj(col_in));
    const col = mergedCollection(s) orelse return null;
    selLock(s);
    defer selUnlock(s);
    var is_update = false;
    if (t.in_col) |prev_c| {
        const prev = prev_c.collection;
        if (identical(col, prev)) {
            c.gst_object_unref(col);
            return null;
        }
        if (c.gst_stream_collection_get_size(col) > c.gst_stream_collection_get_size(prev)) {
            is_update = true;
            var i: c.guint = 0;
            while (i < c.gst_stream_collection_get_size(prev)) : (i += 1) {
                if (inCollection(col, c.gst_stream_get_stream_id(c.gst_stream_collection_get_stream(prev, i))) == null) {
                    is_update = false;
                    break;
                }
            }
        }
    }
    t.in_col = newCollection(col);
    t.in_col.?.is_update = is_update;
    t.collections = c.g_list_append(t.collections, t.in_col);
    return c.gst_message_new_stream_collection(cm.obj(s), col);
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var msg = msg_in;
    cm.lock(s);
    var cl = listIter(Candidate, t.candidates);
    while (cl.next()) |cand| {
        if (cm.obj(cand.element) != msg.*.src) continue;
        if (msg.*.type == c.GST_MESSAGE_ERROR) {
            if (cand.err != null) c.gst_message_unref(cand.err);
            cand.err = msg;
            cm.unlock(s);
            return;
        } else if (msg.*.type == c.GST_MESSAGE_LATENCY) {
            if (cand.latency != null) c.gst_message_unref(cand.latency);
            cand.latency = msg;
            cm.unlock(s);
            return;
        }
        break;
    }
    cm.unlock(s);
    switch (msg.*.type) {
        c.GST_MESSAGE_STREAM_COLLECTION => blk: {
            inLock(s);
            const input = inputForChild(s, msg.*.src) orelse {
                inUnlock(s);
                break :blk;
            };
            if (input.upstream_selected != 0) {
                inUnlock(s);
                c.gst_message_unref(msg);
                return;
            }
            var col: ?*c.GstStreamCollection = null;
            c.gst_message_parse_stream_collection(msg, &col);
            if (col == null) {
                inUnlock(s);
                break :blk;
            }
            const nm = handleCollectionLocked(s, col, input);
            inUnlock(s);
            if (nm != null) {
                c.gst_message_unref(msg);
                msg = nm;
            }
            c.gst_object_unref(col);
        },
        c.GST_MESSAGE_LATENCY => {
            selLock(s);
            var it = listIter(Output, t.outputs);
            while (it.next()) |o| {
                if (o.decoder == null or cm.obj(o.decoder) != msg.*.src) continue;
                if (cm.isA(o.decoder, c.gst_video_decoder_get_type())) {
                    var mn: u64 = 0;
                    var mx: u64 = 0;
                    c.gst_video_decoder_get_latency(@ptrCast(@alignCast(o.decoder)), &mn, &mx);
                    o.latency = mn;
                    updateInterleave(s);
                }
                break;
            }
            selUnlock(s);
        },
        c.GST_MESSAGE_WARNING, c.GST_MESSAGE_ERROR, c.GST_MESSAGE_INFO => {
            var it = listIter(Output, t.outputs);
            while (it.next()) |o| {
                const d = o.decoder orelse continue;
                if (msg.*.src == cm.obj(d) or c.gst_object_has_as_ancestor(msg.*.src, cm.obj(d)) != 0) {
                    msg = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(msg)));
                    c.gst_structure_set(c.gst_message_writable_details(msg), "stream-id", c.G_TYPE_STRING, o.slot.?.active_id, N);
                    break;
                }
            }
        },
        else => {},
    }
    parent_class.?.handle_message.?(b, msg);
}

fn storedLatency(s: *Self, o: *Output, cand: *Candidate) void {
    if (cand.latency == null or !cm.isA(cand.element, c.gst_video_decoder_get_type())) return;
    var mn: u64 = 0;
    var mx: u64 = 0;
    c.gst_video_decoder_get_latency(@ptrCast(@alignCast(cand.element)), &mn, &mx);
    o.latency = mn;
    updateInterleave(s);
    parent_class.?.handle_message.?(binOf(s), cand.latency);
}

fn freeCompatibleOutput(s: *Self, stream: ?*c.GstStream) ?*Output {
    const kind = c.gst_stream_get_stream_type(stream);
    var it = listIter(Output, st(s).outputs);
    while (it.next()) |o| {
        if (o.kind == kind and o.slot != null and o.slot.?.active != null and !isRequested(s, o.slot.?.active_id)) return o;
    }
    return null;
}

fn setOutput(slot: *Slot, output: ?*Output) ?*Output {
    const old = slot.output;
    if (old == output) return output;
    if (old) |o| {
        if (o.decoder_sink != null and o.decoder != null) _ = c.gst_pad_unlink(slot.src_pad, o.decoder_sink);
        o.linked = false;
        o.slot = null;
    }
    if (output) |o| o.slot = slot;
    slot.output = output;
    return old;
}

fn getOrCreateOutput(slot: *Slot) ?*Output {
    const s = slot.bin;
    if (slot.output) |o| return o;
    if (!isRequested(s, slot.active_id) and !st(s).upstream_selects) return null;
    if (freeCompatibleOutput(s, slot.active)) |o| {
        selUnlock(s);
        _ = c.gst_pad_add_probe(o.slot.?.src_pad, c.GST_PAD_PROBE_TYPE_IDLE, unassignProbe, o.slot.?, null);
        selLock(s);
        return null;
    }
    const o = newOutput(s, slot.kind);
    _ = setOutput(slot, o);
    return o;
}

fn selectionDone(s: *Self) [*c]c.GstMessage {
    const t = st(s);
    if (t.upstream_selects) return null;
    const col = t.out_col orelse return null;
    if (col.posted_selected or col.to_activate != null) return null;
    var l = col.requested;
    while (l != null) : (l = l.*.next) if (!isActive(s, @ptrCast(l.*.data))) return null;
    const msg = c.gst_message_new_streams_selected(cm.obj(s), col.collection);
    if (col.seqnum != SEQNUM_INVALID) c.gst_message_set_seqnum(msg, col.seqnum);
    var it = listIter(Slot, t.slots);
    while (it.next()) |slot| {
        if (slot.output == null) continue;
        if (!isRequested(s, slot.active_id)) {
            c.gst_message_unref(msg);
            return null;
        }
        c.gst_message_streams_selected_add(msg, slot.active);
    }
    col.posted_selected = true;
    return msg;
}

fn noMoreStreams(s: *Self) bool {
    const t = st(s);
    const col = t.out_col orelse return false;
    if (col.requested != null) return false;
    var it = listIter(Slot, t.slots);
    while (it.next()) |slot| if (slot.output != null) return false;
    return true;
}

fn checkReconfiguration(slot: *Slot) void {
    const s = slot.bin;
    const t = st(s);
    const col = t.out_col;
    selLock(s);
    const output = getOrCreateOutput(slot) orelse {
        const none = noMoreStreams(s);
        selUnlock(s);
        if (none and slot.kind != c.GST_STREAM_TYPE_UNKNOWN) streamError(s, "No streams to output", "mq_slot_check_reconfiguration", 3233);
        return;
    };
    var msg: [*c]c.GstMessage = null;
    if (!reconfigureOutput(output, &msg)) {
        col.?.requested = removeFromList(col.?.requested, slot.active_id);
        col.?.posted_selected = false;
        _ = setOutput(slot, null);
        t.outputs = c.g_list_remove(t.outputs, output);
        freeOutput(output);
        const none = noMoreStreams(s);
        selUnlock(s);
        if (msg != null) _ = c.gst_element_post_message(elem(s), msg);
        if (none) {
            cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No suitable plugins found"), FILE, "mq_slot_check_reconfiguration", 3258);
            return;
        }
        cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("Some plugins were missing"), FILE, "mq_slot_check_reconfiguration", 3263);
        selLock(s);
    }
    const sel = selectionDone(s);
    selUnlock(s);
    if (sel != null) _ = c.gst_element_post_message(elem(s), sel);
}

fn updatePresence(s: *Self, col: *Collection) void {
    const t = st(s);
    if (t.upstream_selects) {
        col.all_present = true;
        return;
    }
    const len = c.gst_stream_collection_get_size(col.collection);
    if (c.g_list_length(t.slots) < len) {
        col.all_present = false;
        return;
    }
    var i: c.guint = 0;
    while (i < len) : (i += 1) {
        const stream = c.gst_stream_collection_get_stream(col.collection, i);
        var found = false;
        var it = listIter(Slot, t.slots);
        while (it.next()) |slot| {
            if (c.g_strcmp0(stream.*.stream_id, slot.active_id) == 0) {
                found = true;
                break;
            }
        }
        if (!found) {
            col.all_present = false;
            return;
        }
    }
    col.all_present = true;
}

fn slotStreamStart(slot: *Slot, ev: ?*c.GstEvent) c.GstPadProbeReturn {
    const s = slot.bin;
    const t = st(s);
    const sct = c.gst_event_get_structure(ev);
    if (sct != null and c.gst_structure_has_field(sct, "decodebin3-flushing-stream-start") != 0) {
        c.gst_event_unref(ev);
        return c.GST_PAD_PROBE_HANDLED;
    }
    var stream: ?*c.GstStream = null;
    c.gst_event_parse_stream(ev, &stream);
    if (stream == null) return c.GST_PAD_PROBE_OK;
    selLock(s);
    defer {
        c.gst_object_unref(stream);
        selUnlock(s);
    }
    slot.drained = false;
    if (slot.active == stream) return c.GST_PAD_PROBE_OK;
    _ = c.gst_object_replace(@ptrCast(&slot.active), cm.obj(stream));
    slot.active_id = c.gst_stream_get_stream_id(stream);
    if (slot.output) |prev| if (prev.kind != c.gst_stream_get_stream_type(stream)) {
        _ = setOutput(slot, null);
        t.outputs = c.g_list_remove(t.outputs, prev);
        freeOutput(prev);
    };
    const col = collectionForStream(s, slot.active_id).?;
    updatePresence(s, col);
    if (col != t.out_col) {
        updateRequested(s, col);
        var l = t.collections;
        while (l != null) {
            const cand: *Collection = @ptrCast(@alignCast(l.*.data));
            const nx = l.*.next;
            if (cand == col) break;
            if (cand != t.out_col) {
                t.collections = c.g_list_remove(t.collections, cand);
                freeCollection(cand);
            }
            l = nx;
        }
        if (t.out_col == null) {
            t.out_col = col;
        } else if (col.all_present) {
            t.collections = c.g_list_remove(t.collections, t.out_col);
            freeCollection(t.out_col.?);
            t.out_col = col;
        }
    }
    if (!t.upstream_selects and col == t.out_col) streamSwitch(s);
    return c.GST_PAD_PROBE_OK;
}

fn mqSrcProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const slot: *Slot = @ptrCast(@alignCast(data));
    const s = slot.bin;
    if (cm.isEvent(info.*.data)) {
        const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
        switch (cm.eventType(ev)) {
            c.GST_EVENT_STREAM_START => return slotStreamStart(slot, ev),
            c.GST_EVENT_CAPS => checkReconfiguration(slot),
            c.GST_EVENT_EOS => {
                slot.drained = true;
                if (slot.input == null) {
                    if (c.gst_pad_get_peer(pad)) |peer| {
                        _ = c.gst_pad_send_event(peer, c.gst_event_ref(ev));
                        c.gst_object_unref(peer);
                    }
                    selLock(s);
                    removeSlotStreaming(s, slot);
                    selUnlock(s);
                    return c.GST_PAD_PROBE_REMOVE;
                }
            },
            else => {},
        }
    } else if (cm.isQuery(info.*.data)) {
        const q: ?*c.GstQuery = @ptrCast(@alignCast(info.*.data));
        switch (cm.queryType(q)) {
            c.GST_QUERY_CAPS => {
                c.gst_query_set_caps_result(q, c.gst_caps_new_any());
                return c.GST_PAD_PROBE_HANDLED;
            },
            c.GST_QUERY_ACCEPT_CAPS => {
                c.gst_query_set_accept_caps_result(q, 1);
                return c.GST_PAD_PROBE_HANDLED;
            },
            else => {},
        }
    }
    return c.GST_PAD_PROBE_OK;
}

fn createSlot(s: *Self, kind: c.GstStreamType) ?*Slot {
    const t = st(s);
    const slot = A.create(Slot) catch @panic("oom");
    slot.* = .{ .id = t.slot_id, .bin = s, .kind = kind };
    t.slot_id += 1;
    slot.sink_pad = c.gst_element_request_pad_simple(t.mq, "sink_%u");
    if (slot.sink_pad == null) {
        A.destroy(slot);
        return null;
    }
    const it = c.gst_pad_iterate_internal_links(slot.sink_pad);
    var item = std.mem.zeroes(c.GValue);
    if (it == null or c.gst_iterator_next(it, &item) != c.GST_ITERATOR_OK) {
        if (it != null) c.gst_iterator_free(it);
        c.gst_element_release_request_pad(t.mq, slot.sink_pad);
        A.destroy(slot);
        return null;
    }
    slot.src_pad = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
    c.gst_iterator_free(it);
    c.g_value_unset(&item);
    c.g_object_set(gobj(slot.sink_pad), "group-id", @as(c.guint, @intCast(kind)), N);
    slot.probe = c.gst_pad_add_probe(slot.src_pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_QUERY_DOWNSTREAM, mqSrcProbe, slot, null);
    t.slots = c.g_list_append(t.slots, slot);
    return slot;
}

fn slotForInput(s: *Self, in: *InStream) ?*Slot {
    const t = st(s);
    var kind: c.GstStreamType = 0;
    var sid: [*c]const u8 = null;
    if (in.active) |a| {
        kind = c.gst_stream_get_stream_type(a);
        sid = c.gst_stream_get_stream_id(a);
    }
    var it = listIter(Slot, t.slots);
    while (it.next()) |slot| {
        if (slot.input == in) {
            if (kind != 0 and slot.kind != kind) slot.kind = kind;
            return slot;
        }
    }
    var empty: ?*Slot = null;
    it = listIter(Slot, t.slots);
    while (it.next()) |slot| {
        if (slot.input == null and kind == slot.kind) {
            empty = slot;
            if (sid != null and slot.active != null and c.g_strcmp0(sid, slot.active_id) == 0) break;
        }
    }
    if (empty) |e| return e;
    if (kind != 0) return createSlot(s, kind);
    return null;
}

fn linkToSlot(in: *InStream) void {
    const s = in.bin;
    const slot = slotForInput(s, in) orelse {
        streamError(s, "Fatal, could not get a multiqueue slot for input stream", "gst_decodebin_input_link_to_slot", 3701);
        return;
    };
    if (slot.input != null and slot.input != in) return;
    _ = c.gst_pad_link_full(in.srcpad, slot.sink_pad, c.GST_PAD_LINK_CHECK_NOTHING);
    slot.pending = in.active;
    slot.input = in;
}

fn decoderFactories(s: *Self, caps: [*c]c.GstCaps) [*c]c.GList {
    const t = st(s);
    c.g_mutex_lock(&t.fac_lock);
    defer c.g_mutex_unlock(&t.fac_lock);
    updateFactories(s);
    return c.gst_element_factory_list_filter(t.decoders, caps, c.GST_PAD_SINK, 1);
}

fn keyframeWaiter(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const slot: *Slot = @ptrCast(@alignCast(data));
    const b = cm.buf(info.*.data);
    const fl = b.mini_object.flags;
    if ((fl & c.GST_BUFFER_FLAG_DELTA_UNIT) == 0 or (fl & c.GST_BUFFER_FLAG_HEADER) != 0) {
        slot.drop_probe = 0;
        return c.GST_PAD_PROBE_REMOVE;
    }
    return c.GST_PAD_PROBE_DROP;
}

fn clearSticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_event_unref(ev.*);
    ev.* = null;
    return 1;
}

fn copySticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_store_sticky_event(@ptrCast(@alignCast(data)), ev.*);
    return 1;
}

fn decodePadTarget(pad: ?*c.GstPad, target: ?*c.GstPad) bool {
    if (c.gst_ghost_pad_set_target(ghost(pad), target) == 0) return false;
    if (target == null) {
        _ = c.gst_pad_sticky_events_foreach(pad, clearSticky, null);
    } else _ = c.gst_pad_sticky_events_foreach(target, copySticky, pad);
    return true;
}

fn exposeSrc(o: *Output) void {
    if (o.exposed) return;
    const slot = o.slot.?;
    if (c.gst_pad_get_sticky_event(slot.src_pad, c.GST_EVENT_STREAM_START, 0)) |ss| {
        _ = c.gst_pad_store_sticky_event(o.src_pad, ss);
        c.gst_event_unref(ss);
    }
    o.exposed = true;
    _ = c.gst_element_add_pad(elem(slot.bin), o.src_pad);
}

fn addCandidate(s: *Self, e: ?*c.GstElement) *Candidate {
    cm.lock(s);
    defer cm.unlock(s);
    const cand = A.create(Candidate) catch @panic("oom");
    cand.* = .{ .element = e };
    st(s).candidates = c.g_list_prepend(st(s).candidates, cand);
    return cand;
}

fn removeCandidate(s: *Self, cand: *Candidate) void {
    cm.lock(s);
    defer cm.unlock(s);
    st(s).candidates = c.g_list_remove(st(s).candidates, cand);
    if (cand.err != null) c.gst_message_unref(cand.err);
    A.destroy(cand);
}

fn addDropProbe(o: *Output, slot: *Slot) void {
    if ((o.kind & c.GST_STREAM_TYPE_VIDEO) != 0 and slot.drop_probe == 0) slot.drop_probe = c.gst_pad_add_probe(slot.src_pad, c.GST_PAD_PROBE_TYPE_BUFFER, keyframeWaiter, slot, null);
}

fn setupDecoder(o: *Output, caps: [*c]c.GstCaps, msg: *[*c]c.GstMessage) bool {
    const s = o.bin;
    const slot = o.slot.?;
    if (c.gst_caps_can_intersect(caps, st(s).caps) != 0) {
        o.decoder_src = ref(slot.src_pad.?);
        return finishDecoder(o, slot, true);
    }
    const factories = decoderFactories(s, caps);
    if (factories == null) return missingDecoder(o, slot, msg);
    var next = factories;
    while (next != null) {
        var cand: ?*Candidate = null;
        var ok = false;
        o.decoder = c.gst_element_factory_create(@ptrCast(@alignCast(next.*.data)), null);
        if (o.decoder != null and c.gst_bin_add(binOf(s), o.decoder) != 0) {
            o.decoder_sink = c.gst_element_get_static_pad(o.decoder, "sink");
            o.decoder_src = c.gst_element_get_static_pad(o.decoder, "src");
            cand = addCandidate(s, o.decoder);
            if (c.gst_pad_link_full(slot.src_pad, o.decoder_sink, c.GST_PAD_LINK_CHECK_NOTHING) == c.GST_PAD_LINK_OK) {
                o.linked = true;
                if (c.gst_element_set_state(o.decoder, c.GST_STATE_READY) != c.GST_STATE_CHANGE_FAILURE and
                    c.gst_pad_query_accept_caps(o.decoder_sink, caps) != 0 and
                    c.gst_element_set_state(o.decoder, c.GST_STATE_PAUSED) != c.GST_STATE_CHANGE_FAILURE) ok = true;
            }
        }
        if (ok) {
            storedLatency(s, o, cand.?);
            removeCandidate(s, cand.?);
            break;
        }
        resetOutput(o);
        if (cand) |x| removeCandidate(s, x);
        if (next.*.next == null) {
            c.gst_plugin_feature_list_free(factories);
            if (o.decoder == null) return missingDecoder(o, slot, msg);
            return cleanupDecoder(o, false);
        }
        next = next.*.next;
    }
    c.gst_plugin_feature_list_free(factories);
    return finishDecoder(o, slot, true);
}

fn finishDecoder(o: *Output, slot: *Slot, ret: bool) bool {
    addDropProbe(o, slot);
    _ = decodePadTarget(o.src_pad, o.decoder_src);
    exposeSrc(o);
    if (o.decoder) |d| _ = c.gst_element_sync_state_with_parent(d);
    return ret;
}

fn missingDecoder(o: *Output, slot: *Slot, msg: *[*c]c.GstMessage) bool {
    const caps = c.gst_stream_get_caps(slot.active);
    msg.* = c.gst_missing_decoder_message_new(elem(o.bin), caps);
    c.gst_missing_plugin_message_set_stream_id(msg.*, c.gst_stream_get_stream_id(slot.active));
    c.gst_caps_unref(caps);
    return cleanupDecoder(o, false);
}

fn cleanupDecoder(o: *Output, ret: bool) bool {
    if (o.decoder_sink) |p| c.gst_object_unref(p);
    o.decoder_sink = null;
    if (o.decoder_src) |p| c.gst_object_unref(p);
    o.decoder_src = null;
    if (o.decoder) |d| {
        _ = c.gst_element_set_state(d, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(o.bin), d);
        o.decoder = null;
    }
    return ret;
}

fn reconfigureOutput(o: *Output, msg: *[*c]c.GstMessage) bool {
    const slot = o.slot.?;
    const caps = c.gst_stream_get_caps(slot.active);
    defer c.gst_caps_unref(caps);
    const needs = c.gst_caps_can_intersect(caps, st(o.bin).caps) == 0;
    if (needs and o.decoder != null and c.gst_pad_query_accept_caps(o.decoder_sink, caps) != 0) {
        addDropProbe(o, slot);
        if (!o.linked) {
            _ = c.gst_pad_link_full(slot.src_pad, o.decoder_sink, c.GST_PAD_LINK_CHECK_NOTHING);
            o.linked = true;
        }
        return true;
    }
    resetOutput(o);
    return setupDecoder(o, caps, msg);
}

fn idleReconfigure(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    checkReconfiguration(@ptrCast(@alignCast(data)));
    return c.GST_PAD_PROBE_REMOVE;
}

fn slotForStreamId(s: *Self, sid: [*c]const u8) ?*Slot {
    var it = listIter(Slot, st(s).slots);
    while (it.next()) |slot| {
        if (c.g_strcmp0(sid, slot.active_id) == 0) return slot;
        if (slot.pending != null and slot.pending != slot.active and c.g_strcmp0(sid, c.gst_stream_get_stream_id(slot.pending)) == 0) return slot;
    }
    return null;
}

fn reassign(slot: *Slot) void {
    const s = slot.bin;
    const t = st(s);
    const col = t.out_col;
    selLock(s);
    const output = slot.output;
    if (slot.active == null or output == null) {
        selUnlock(s);
        return;
    }
    if (isRequested(s, slot.active_id)) {
        selUnlock(s);
        return;
    }
    _ = setOutput(slot, null);
    var target: ?*Slot = null;
    var l = col.?.to_activate;
    while (l != null) : (l = l.*.next) {
        const ts = slotForStreamId(s, @ptrCast(l.*.data));
        if (ts != null and ts.?.kind == output.?.kind and ts.?.output == null) {
            target = ts;
            col.?.to_activate = c.g_list_delete_link(col.?.to_activate, l);
            break;
        }
    }
    if (target) |ts| {
        _ = setOutput(ts, output);
        selUnlock(s);
        _ = c.gst_pad_add_probe(ts.src_pad, c.GST_PAD_PROBE_TYPE_IDLE, idleReconfigure, ts, null);
    } else {
        t.outputs = c.g_list_remove(t.outputs, output);
        freeOutput(output.?);
        const msg = selectionDone(s);
        selUnlock(s);
        if (msg != null) _ = c.gst_element_post_message(elem(s), msg);
    }
}

fn unassignProbe(_: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    reassign(@ptrCast(@alignCast(data)));
    return c.GST_PAD_PROBE_REMOVE;
}

fn streamSwitch(s: *Self) void {
    const t = st(s);
    const col = t.out_col orelse {
        _ = cm.that(false, "handle_stream_switch", "collection");
        return;
    };
    if (!col.all_present) return;
    var deactivate: [*c]c.GList = null;
    var activate: [*c]c.GList = null;
    var reassign_streams: [*c]c.GList = null;
    var pending: [*c]c.GList = null;
    var to_reassign: [*c]c.GList = null;
    var l = col.requested;
    while (l != null) : (l = l.*.next) {
        const sid: [*c]const u8 = @ptrCast(l.*.data);
        const slot = slotForStreamId(s, sid);
        if (slot == null or slot.?.active == null) {
            pending = c.g_list_append(pending, @constCast(sid));
        } else if (slot.?.output == null) activate = c.g_list_append(activate, slot);
    }
    var it = listIter(Slot, t.slots);
    while (it.next()) |slot| {
        if (slot.output == null) continue;
        var off = true;
        if (slot.active != null and inList(col.requested, slot.active_id) != null) off = false;
        if (off and slot.pending != null and slot.pending != slot.active and inList(col.requested, c.gst_stream_get_stream_id(slot.pending)) != null) off = false;
        if (off) deactivate = c.g_list_append(deactivate, slot);
    }
    var d = deactivate;
    while (d != null) {
        const sd: *Slot = @ptrCast(@alignCast(d.*.data));
        var remove_it = false;
        var a = activate;
        while (a != null) : (a = a.*.next) {
            const sa: *Slot = @ptrCast(@alignCast(a.*.data));
            if (sa.kind == sd.kind) {
                reassign_streams = c.g_list_append(reassign_streams, @constCast(sa.active_id));
                to_reassign = c.g_list_append(to_reassign, sd);
                activate = c.g_list_remove(activate, sa);
                remove_it = true;
                break;
            }
        }
        const nx = d.*.next;
        if (remove_it) deactivate = c.g_list_delete_link(deactivate, d);
        d = nx;
    }
    d = deactivate;
    while (d != null) : (d = d.*.next) to_reassign = c.g_list_append(to_reassign, d.*.data);
    if (activate == null and pending != null) {
        c.g_list_free(deactivate);
        c.g_list_free(pending);
        deactivate = null;
        pending = null;
    } else {
        if (col.to_activate != null) c.g_list_free(col.to_activate);
        col.to_activate = c.g_list_copy(reassign_streams);
    }
    selUnlock(s);
    if (activate != null and to_reassign == null) {
        var a = activate;
        while (a != null) : (a = a.*.next) {
            const sa: *Slot = @ptrCast(@alignCast(a.*.data));
            _ = c.gst_pad_add_probe(sa.src_pad, c.GST_PAD_PROBE_TYPE_IDLE, idleReconfigure, sa, null);
        }
    }
    var r = to_reassign;
    while (r != null) : (r = r.*.next) {
        const sr: *Slot = @ptrCast(@alignCast(r.*.data));
        _ = c.gst_pad_add_probe(sr.src_pad, c.GST_PAD_PROBE_TYPE_IDLE, unassignProbe, sr, null);
    }
    c.g_list_free(deactivate);
    c.g_list_free(activate);
    c.g_list_free(reassign_streams);
    c.g_list_free(pending);
    c.g_list_free(to_reassign);
    selLock(s);
}

fn handleSelectStreams(s: *Self, ev: ?*c.GstEvent) bool {
    const t = st(s);
    if (t.upstream_selects) return false;
    const seqnum = c.gst_event_get_seqnum(ev);
    var streams: [*c]c.GList = null;
    c.gst_event_parse_select_streams(ev, &streams);
    if (streams == null) {
        c.gst_event_unref(ev);
        return true;
    }
    selLock(s);
    defer {
        selUnlock(s);
        c.gst_event_unref(ev);
    }
    var found: ?*Collection = null;
    var it = listIter(Collection, t.collections);
    while (it.next()) |cand| {
        if (allInCollection(cand.collection, streams)) {
            found = cand;
            break;
        }
    }
    const col = found orelse return true;
    if (seqnum == col.seqnum) return true;
    if (col.requested != null) c.g_list_free_full(col.requested, c.g_free);
    col.requested = streams;
    col.seqnum = seqnum;
    col.posted_selected = false;
    if (col == t.out_col) streamSwitch(s);
    return true;
}

fn ghostEventProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const o: *Output = @ptrCast(@alignCast(data));
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    if (cm.eventType(ev) == c.GST_EVENT_SELECT_STREAMS and handleSelectStreams(o.bin, ev)) return c.GST_PAD_PROBE_HANDLED;
    return c.GST_PAD_PROBE_OK;
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_SELECT_STREAMS and handleSelectStreams(me(e), ev)) return 1;
    return @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).send_event.?(e, ev);
}

fn freeSlot(s: *Self, slot: *Slot) void {
    if (slot.probe != 0) c.gst_pad_remove_probe(slot.src_pad, slot.probe);
    if (slot.drop_probe != 0) c.gst_pad_remove_probe(slot.src_pad, slot.drop_probe);
    if (slot.input) |in| if (in.srcpad != null) {
        _ = c.gst_pad_unlink(in.srcpad, slot.sink_pad);
    };
    c.gst_element_release_request_pad(st(s).mq, slot.sink_pad);
    _ = c.gst_object_replace(@ptrCast(&slot.sink_pad), null);
    _ = c.gst_object_replace(@ptrCast(&slot.src_pad), null);
    _ = c.gst_object_replace(@ptrCast(&slot.active), null);
    A.destroy(slot);
}

fn newOutput(s: *Self, kind: c.GstStreamType) *Output {
    const t = st(s);
    const o = A.create(Output) catch @panic("oom");
    o.* = .{ .bin = s, .kind = kind };
    var templ: *c.GstStaticPadTemplate = &src_t;
    var counter: *u32 = &t.opad;
    var prefix: [*c]const u8 = "src";
    if ((kind & c.GST_STREAM_TYPE_VIDEO) != 0) {
        templ = &video_t;
        counter = &t.vpad;
        prefix = "video";
    } else if ((kind & c.GST_STREAM_TYPE_AUDIO) != 0) {
        templ = &audio_t;
        counter = &t.apad;
        prefix = "audio";
    } else if ((kind & c.GST_STREAM_TYPE_TEXT) != 0) {
        templ = &text_t;
        counter = &t.tpad;
        prefix = "text";
    } else if ((kind & c.GST_STREAM_TYPE_METADATA) != 0) {
        templ = &meta_t;
        counter = &t.mpad;
        prefix = "metadata";
    }
    const name = c.g_strdup_printf("%s_%u", prefix, counter.*);
    counter.* += 1;
    const pt = c.gst_static_pad_template_get(templ);
    o.src_pad = c.gst_ghost_pad_new_no_target_from_template(name, pt);
    c.gst_object_unref(pt);
    c.g_free(name);
    _ = c.gst_pad_set_active(o.src_pad, 1);
    const internal: ?*c.GstPad = @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(o.src_pad)))));
    _ = c.gst_pad_add_probe(internal, c.GST_PAD_PROBE_TYPE_EVENT_UPSTREAM, ghostEventProbe, o, null);
    c.gst_object_unref(internal);
    t.outputs = c.g_list_append(t.outputs, o);
    return o;
}

fn resetOutput(o: *Output) void {
    const slot = o.slot;
    if (o.linked and slot != null and o.decoder_sink != null) _ = c.gst_pad_unlink(slot.?.src_pad, o.decoder_sink);
    o.linked = false;
    if (slot) |x| if (x.drop_probe != 0) {
        c.gst_pad_remove_probe(x.src_pad, x.drop_probe);
        x.drop_probe = 0;
    };
    _ = c.gst_object_replace(@ptrCast(&o.decoder_sink), null);
    _ = decodePadTarget(o.src_pad, null);
    _ = c.gst_object_replace(@ptrCast(&o.decoder_src), null);
    if (o.decoder) |d| {
        _ = c.gst_element_set_locked_state(d, 1);
        _ = c.gst_element_set_state(d, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(o.bin), d);
        o.decoder = null;
        o.latency = cm.CLOCK_NONE;
    }
}

fn freeOutput(o: *Output) void {
    resetOutput(o);
    if (o.slot) |x| _ = setOutput(x, null);
    if (o.exposed) {
        _ = c.gst_element_remove_pad(elem(o.bin), o.src_pad);
    } else if (o.src_pad) |p| {
        c.gst_object_unref(p);
        o.src_pad = null;
    }
    A.destroy(o);
}

fn reset(s: *Self) void {
    const t = st(s);
    selLock(s);
    var l = t.outputs;
    while (l != null) {
        const nx = l.*.next;
        freeOutput(@ptrCast(@alignCast(l.*.data)));
        l = nx;
    }
    c.g_list_free(t.outputs);
    t.outputs = null;
    l = t.slots;
    while (l != null) : (l = l.*.next) freeSlot(s, @ptrCast(@alignCast(l.*.data)));
    c.g_list_free(t.slots);
    t.slots = null;
    t.group_id = GROUP_INVALID;
    selUnlock(s);
    var it = listIter(Input, t.inputs);
    while (it.next()) |x| resetInput(x);
    c.g_object_set(gobj(t.mq), "min-interleave-time", t.default_interleave, N);
    selLock(s);
    t.interleave = t.default_interleave;
    t.upstream_selects = false;
    c.g_list_free_full(t.collections, @ptrCast(&freeCollectionC));
    t.collections = null;
    t.in_col = null;
    t.out_col = null;
    selUnlock(s);
}

fn freeCollectionC(p: c.gpointer) callconv(.c) void {
    freeCollection(@ptrCast(@alignCast(p)));
}

fn changeState(e: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, tr);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (tr == c.GST_STATE_CHANGE_PAUSED_TO_READY) reset(me(e));
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            if (st(s).caps != null) c.gst_caps_unref(st(s).caps);
            st(s).caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 861),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            c.g_value_set_boxed(v, st(s).caps);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 879),
    }
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    reset(s);
    c.g_mutex_lock(&t.fac_lock);
    if (t.factories != null) c.gst_plugin_feature_list_free(t.factories);
    t.factories = null;
    if (t.decoders != null) c.g_list_free(t.decoders);
    t.decoders = null;
    if (t.decodables != null) c.g_list_free(t.decodables);
    t.decodables = null;
    c.g_mutex_unlock(&t.fac_lock);
    inLock(s);
    while (t.inputs != null) {
        const x: *Input = @ptrCast(@alignCast(t.inputs.*.data));
        if (x.is_main) t.main = null;
        freeInput(x);
        t.inputs = c.g_list_delete_link(t.inputs, t.inputs);
    }
    if (t.main) |m| freeInput(m);
    t.main = null;
    inUnlock(s);
    if (t.caps != null) c.gst_caps_unref(t.caps);
    t.caps = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = st(o);
    c.g_mutex_clear(&t.fac_lock);
    c.g_mutex_clear(&t.sel_lock);
    c.g_mutex_clear(&t.input_lock);
    c.g_cond_clear(&t.posting_cond);
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
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The caps on which to stop decoding. (NULL = default)", c.gst_caps_get_type(), cm.RW));
    const t = cm.typeOfClass(k);
    signals[SIG_SELECT_STREAM] = c.g_signal_new("select-stream", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "select_stream"), intAccu, null, null, c.G_TYPE_INT, 2, c.gst_stream_collection_get_type(), c.gst_stream_get_type());
    signals[SIG_ABOUT_TO_FINISH] = c.g_signal_new("about-to-finish", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestNewPad;
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    ec.release_pad = releasePad;
    inline for (.{ &sink_t, &req_sink_t, &video_t, &audio_t, &text_t, &meta_t, &src_t }) |tp| c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(tp));
    c.gst_element_class_set_static_metadata(ec, "Decoder Bin 3", "Generic/Bin/Decoder", "Autoplug and decode to raw media", "Edward Hervey <edward@centricular.com>");
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.select_stream = defaultSelect;
    _ = c._gst_debug_category_new("decodebin3", 0, "decoder bin");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    t.main = newInput(s, true);
    t.mq = c.gst_element_factory_make("multiqueue", null);
    c.g_object_get(gobj(t.mq), "min-interleave-time", &t.default_interleave, N);
    t.interleave = t.default_interleave;
    c.g_object_set(gobj(t.mq), "sync-by-running-time", @as(c.gboolean, 1), "max-size-buffers", @as(c.guint, 0), "use-interleave", @as(c.gboolean, 1), N);
    _ = c.gst_bin_add(binOf(s), t.mq);
    t.group_id = GROUP_INVALID;
    c.g_mutex_init(&t.fac_lock);
    c.g_mutex_init(&t.sel_lock);
    c.g_mutex_init(&t.input_lock);
    c.g_cond_init(&t.posting_cond);
    t.posting = false;
    t.caps = utils.rawCaps();
    cm.obj(s).flags |= c.GST_BIN_FLAG_STREAMS_AWARE;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstDecodebin3", Class, Self, classInit, init);
        }
    }.f);
}
