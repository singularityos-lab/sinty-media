const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const playsink = @import("playsink.zig");
const subtitleoverlay = @import("subtitleoverlay.zig");

const FILE = "../gst/playback/gstplaybin3.c";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const VOLUME_MAX = 10.0;
const DEFAULT_FLAGS = flags.AUDIO | flags.VIDEO | flags.TEXT | flags.SOFT_VOLUME | flags.DEINTERLACE | flags.SOFT_COLORBALANCE | flags.BUFFERING;

const PROP_URI = 1;
const PROP_CURRENT_URI = 2;
const PROP_SUBURI = 3;
const PROP_CURRENT_SUBURI = 4;
const PROP_FLAGS = 5;
const PROP_SUBTITLE_ENCODING = 6;
const PROP_AUDIO_SINK = 7;
const PROP_VIDEO_SINK = 8;
const PROP_VIS_PLUGIN = 9;
const PROP_TEXT_SINK = 10;
const PROP_VIDEO_STREAM_COMBINER = 11;
const PROP_AUDIO_STREAM_COMBINER = 12;
const PROP_TEXT_STREAM_COMBINER = 13;
const PROP_VOLUME = 14;
const PROP_MUTE = 15;
const PROP_SAMPLE = 16;
const PROP_FONT_DESC = 17;
const PROP_CONNECTION_SPEED = 18;
const PROP_BUFFER_SIZE = 19;
const PROP_BUFFER_DURATION = 20;
const PROP_AV_OFFSET = 21;
const PROP_TEXT_OFFSET = 22;
const PROP_RING_BUFFER_MAX_SIZE = 23;
const PROP_FORCE_ASPECT_RATIO = 24;
const PROP_AUDIO_FILTER = 25;
const PROP_VIDEO_FILTER = 26;
const PROP_MULTIVIEW_MODE = 27;
const PROP_MULTIVIEW_FLAGS = 28;
const PROP_INSTANT_URI = 29;

const SIG_ABOUT_TO_FINISH = 0;
const SIG_SOURCE_SETUP = 1;
const SIG_ELEMENT_SETUP = 2;

const Slot = enum(u2) { audio, video, text };
const NAMES = [_][*c]const u8{ "audio", "video", "text" };
const FLUSH = [_][*c]const u8{ "playsink-custom-audio-flush", "playsink-custom-video-flush", "playsink-custom-text-flush" };
const FLUSH_DONE = [_][*c]const u8{ "playsink-custom-audio-flush-finish", "playsink-custom-video-flush-finish", "playsink-custom-subtitle-flush-finish" };
const TYPES = [_]c.GstStreamType{ c.GST_STREAM_TYPE_AUDIO, c.GST_STREAM_TYPE_VIDEO, c.GST_STREAM_TYPE_TEXT };
const KINDS = [_]playsink.Kind{ .audio, .video, .text };

const Combine = struct {
    stype: c.GstStreamType,
    combiner: ?*c.GstElement = null,
    inputs: std.ArrayList(*c.GstPad) = .empty,
    srcpad: ?*c.GstPad = null,
    sinkpad: ?*c.GstPad = null,
    streams: std.ArrayList(*c.GstStream) = .empty,
    has_active_pad: bool = false,
};

const SourcePad = struct {
    pad: ?*c.GstPad,
    stype: c.GstStreamType,
    combine_sink: ?*c.GstPad,
    probe: c.gulong,
};

const State = struct {
    lock: c.GRecMutex = undefined,
    udb: ?*c.GstElement = null,
    sources: std.ArrayList(*SourcePad) = .empty,
    collection: ?*c.GstStreamCollection = null,
    combine: [3]Combine = .{ .{ .stype = TYPES[0] }, .{ .stype = TYPES[1] }, .{ .stype = TYPES[2] } },
    selected: c.GstStreamType = 0,
    active: c.GstStreamType = 0,
    current: [3]c.gint = .{ -1, -1, -1 },
    do_selections: bool = false,
    collection_source: ?*c.GstObject = null,
    mv_mode: c.gint = c.GST_VIDEO_MULTIVIEW_FRAME_PACKING_NONE,
    mv_flags: c.guint = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE,
    sink: ?*playsink.Self = null,
    async_pending: bool = false,
    pending_flush: [3]bool = .{ false, false, false },
    sinks: [3]?*c.GstElement = .{ null, null, null },
    customs: [3]?*c.GstElement = .{ null, null, null },
    is_live: bool = false,
};

pub const Self = extern struct {
    parent: c.GstPipeline,
    st: ?*State,
};

const Class = extern struct {
    parent: c.GstPipelineClass,
    about_to_finish: ?*const fn (?*Self) callconv(.c) void,
    convert_sample: ?*const fn (?*Self, [*c]c.GstCaps) callconv(.c) ?*c.GstSample,
};

var signals: [3]c.guint = .{ 0, 0, 0 };
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

fn ps(s: *Self) *playsink.Self {
    return st(s).sink.?;
}

fn lock(s: *Self) void {
    c.g_rec_mutex_lock(&st(s).lock);
}

fn unlock(s: *Self) void {
    c.g_rec_mutex_unlock(&st(s).lock);
}

fn slotOf(t: c.GstStreamType) ?Slot {
    if (t & c.GST_STREAM_TYPE_AUDIO != 0) return .audio;
    if (t & c.GST_STREAM_TYPE_VIDEO != 0) return .video;
    if (t & c.GST_STREAM_TYPE_TEXT != 0) return .text;
    return null;
}

fn slotOfName(name: [*c]const u8) ?Slot {
    const n = std.mem.span(name);
    if (std.mem.startsWith(u8, n, "video")) return .video;
    if (std.mem.startsWith(u8, n, "audio")) return .audio;
    if (std.mem.startsWith(u8, n, "text")) return .text;
    return null;
}

fn coreError(s: *Self, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_PAD, c.g_strdup("Internal playbin error."), dbg, FILE, func, line);
}

fn parentMessage(s: *Self, m: [*c]c.GstMessage) void {
    parent_class.?.handle_message.?(binOf(s), m);
}

fn asyncStart(s: *Self) void {
    st(s).async_pending = true;
    parentMessage(s, c.gst_message_new_async_start(cm.obj(s)));
}

fn asyncDone(s: *Self) void {
    const t = st(s);
    if (!t.async_pending) return;
    parentMessage(s, c.gst_message_new_async_done(cm.obj(s), cm.CLOCK_NONE));
    t.async_pending = false;
}

fn clearStreams(cb: *Combine) void {
    for (cb.streams.items) |x| c.gst_object_unref(x);
    cb.streams.clearRetainingCapacity();
}

fn updateCombiners(s: *Self, col: ?*c.GstStreamCollection) void {
    const t = st(s);
    const x = col orelse return;
    for (&t.combine) |*cb| clearStreams(cb);
    const n = c.gst_stream_collection_get_size(x);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const stream = c.gst_stream_collection_get_stream(x, i);
        const slot = slotOf(c.gst_stream_get_stream_type(stream)) orelse continue;
        t.combine[@intFromEnum(slot)].streams.append(A, @ptrCast(@alignCast(c.gst_object_ref(stream)))) catch @panic("oom");
    }
}

fn notifyVolume(_: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    c.g_object_notify(gobj(data), "volume");
}

fn notifyMute(_: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    c.g_object_notify(gobj(data), "mute");
}

fn balanceChanged(_: ?*c.GstColorBalance, ch: ?*c.GstColorBalanceChannel, v: c.gint, data: c.gpointer) callconv(.c) void {
    c.gst_color_balance_value_changed(@ptrCast(@alignCast(data)), ch, v);
}

fn sendCustom(combiner: *c.GstElement, name: [*c]const u8) bool {
    const src = c.gst_element_get_static_pad(combiner, "src");
    defer c.gst_object_unref(src);
    const peer = c.gst_pad_get_peer(src) orelse return false;
    _ = c.gst_pad_send_event(peer, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB, c.gst_structure_new_empty(name)));
    c.gst_object_unref(peer);
    return true;
}

fn setCurrent(s: *Self, slot: Slot, stream: c.gint) bool {
    const t = st(s);
    const i = @intFromEnum(slot);
    lock(s);
    t.do_selections = true;
    const cb = &t.combine[i];
    if (cb.combiner == null) {
        t.current[i] = stream;
        doSelection(s);
        unlock(s);
        return true;
    }
    if (!cb.has_active_pad) {
        unlock(s);
        return false;
    }
    const sinkpad: ?*c.GstPad = if (stream < 0 or cb.inputs.items.len <= @as(usize, @intCast(stream))) null else @ptrCast(@alignCast(c.gst_object_ref(cb.inputs.items[@intCast(stream)])));
    unlock(s);
    const pad = sinkpad orelse return true;
    defer c.gst_object_unref(pad);
    const parent: *c.GstElement = @ptrCast(@alignCast(c.gst_pad_get_parent(pad) orelse return true));
    defer c.gst_object_unref(parent);
    var old: ?*c.GstPad = null;
    c.g_object_get(gobj(parent), "active-pad", &old, N);
    if (old != pad) {
        if (sendCustom(parent, FLUSH[i])) t.pending_flush[i] = true;
        c.g_object_set(gobj(parent), "active-pad", pad, N);
    }
    if (old) |o| c.gst_object_unref(o);
    return true;
}

fn setSink(s: *Self, slot: Slot, sink: ?*c.GstElement) void {
    const t = st(s);
    const i = @intFromEnum(slot);
    playsink.setSink(ps(s), KINDS[i], sink);
    if (t.sinks[i]) |o| c.gst_object_unref(o);
    t.sinks[i] = if (sink) |x| @ptrCast(@alignCast(c.gst_object_ref(x))) else null;
}

fn currentSink(s: *Self, slot: Slot) ?*c.GstElement {
    const t = st(s);
    if (playsink.getSink(ps(s), KINDS[@intFromEnum(slot)])) |x| return x;
    lock(s);
    defer unlock(s);
    const x = t.sinks[@intFromEnum(slot)] orelse return null;
    return @ptrCast(@alignCast(c.gst_object_ref(x)));
}

fn setCombiner(s: *Self, slot: Slot, comb: ?*c.GstElement) void {
    const t = st(s);
    const p = &t.customs[@intFromEnum(slot)];
    lock(s);
    defer unlock(s);
    if (p.* == comb) return;
    const old = p.*;
    if (comb) |x| _ = c.gst_object_ref_sink(x);
    p.* = comb;
    if (old) |o| c.gst_object_unref(o);
}

fn setFlags(s: *Self, f: c.guint) void {
    if (f != playsink.getFlags(ps(s))) {
        playsink.setFlags(ps(s), f);
        _ = playsink.requestReconfigure(ps(s));
    }
    c.g_object_set(gobj(st(s).udb), "download", @as(c.gboolean, @intFromBool(f & flags.DOWNLOAD != 0)), "use-buffering", @as(c.gboolean, @intFromBool(f & flags.BUFFERING != 0)), N);
}

fn forward(s: *Self, name: [*c]const u8, v: [*c]const c.GValue) void {
    c.g_object_set_property(gobj(st(s).udb), name, v);
}

fn back(s: *Self, name: [*c]const u8, v: [*c]c.GValue) void {
    c.g_object_get_property(gobj(st(s).udb), name, v);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => c.g_object_set(gobj(t.udb), "uri", c.g_value_get_string(v), N),
        PROP_SUBURI => c.g_object_set(gobj(t.udb), "suburi", c.g_value_get_string(v), N),
        PROP_FLAGS => setFlags(s, c.g_value_get_flags(v)),
        PROP_SUBTITLE_ENCODING => {
            lock(s);
            c.g_object_set_property(gobj(t.sink), "subtitle-encoding", v);
            unlock(s);
        },
        PROP_VIDEO_FILTER => playsink.setFilter(ps(s), .video, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_FILTER => playsink.setFilter(ps(s), .audio, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIDEO_SINK => setSink(s, .video, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_SINK => setSink(s, .audio, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIS_PLUGIN => playsink.setVisPlugin(ps(s), @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_TEXT_SINK => setSink(s, .text, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIDEO_STREAM_COMBINER => setCombiner(s, .video, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_STREAM_COMBINER => setCombiner(s, .audio, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_TEXT_STREAM_COMBINER => setCombiner(s, .text, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VOLUME => playsink.setVolume(ps(s), c.g_value_get_double(v)),
        PROP_MUTE => playsink.setMute(ps(s), c.g_value_get_boolean(v) != 0),
        PROP_FONT_DESC => c.g_object_set_property(gobj(t.sink), "subtitle-font-desc", v),
        PROP_CONNECTION_SPEED => {
            lock(s);
            forward(s, "connection-speed", v);
            unlock(s);
        },
        PROP_BUFFER_SIZE => forward(s, "buffer-size", v),
        PROP_BUFFER_DURATION => forward(s, "buffer-duration", v),
        PROP_AV_OFFSET => c.g_object_set_property(gobj(t.sink), "av-offset", v),
        PROP_TEXT_OFFSET => c.g_object_set_property(gobj(t.sink), "text-offset", v),
        PROP_RING_BUFFER_MAX_SIZE => forward(s, "ring-buffer-max-size", v),
        PROP_FORCE_ASPECT_RATIO => c.g_object_set(gobj(t.sink), "force-aspect-ratio", c.g_value_get_boolean(v), N),
        PROP_MULTIVIEW_MODE => {
            lock(s);
            t.mv_mode = c.g_value_get_enum(v);
            unlock(s);
        },
        PROP_MULTIVIEW_FLAGS => {
            lock(s);
            t.mv_flags = c.g_value_get_flags(v);
            unlock(s);
        },
        PROP_INSTANT_URI => forward(s, "instant-uri", v),
        else => cm.warnInvalid(FILE, o, id, spec, 1535),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => back(s, "uri", v),
        PROP_CURRENT_URI => back(s, "current-uri", v),
        PROP_SUBURI => back(s, "suburi", v),
        PROP_CURRENT_SUBURI => back(s, "current-suburi", v),
        PROP_FLAGS => c.g_value_set_flags(v, playsink.getFlags(ps(s))),
        PROP_SUBTITLE_ENCODING => {
            lock(s);
            c.g_object_get_property(gobj(t.sink), "subtitle-encoding", v);
            unlock(s);
        },
        PROP_VIDEO_FILTER => c.g_value_take_object(v, playsink.getFilter(ps(s), .video)),
        PROP_AUDIO_FILTER => c.g_value_take_object(v, playsink.getFilter(ps(s), .audio)),
        PROP_VIDEO_SINK => c.g_value_take_object(v, currentSink(s, .video)),
        PROP_AUDIO_SINK => c.g_value_take_object(v, currentSink(s, .audio)),
        PROP_VIS_PLUGIN => c.g_value_take_object(v, playsink.getVisPlugin(ps(s))),
        PROP_TEXT_SINK => c.g_value_take_object(v, currentSink(s, .text)),
        PROP_VIDEO_STREAM_COMBINER => c.g_value_set_object(v, t.customs[@intFromEnum(Slot.video)]),
        PROP_AUDIO_STREAM_COMBINER => c.g_value_set_object(v, t.customs[@intFromEnum(Slot.audio)]),
        PROP_TEXT_STREAM_COMBINER => c.g_value_set_object(v, t.customs[@intFromEnum(Slot.text)]),
        PROP_VOLUME => c.g_value_set_double(v, playsink.getVolume(ps(s))),
        PROP_MUTE => c.g_value_set_boolean(v, @intFromBool(playsink.getMute(ps(s)))),
        PROP_SAMPLE => c.gst_value_take_sample(v, playsink.lastSample(ps(s))),
        PROP_FONT_DESC => c.g_object_get_property(gobj(t.sink), "subtitle-font-desc", v),
        PROP_CONNECTION_SPEED => back(s, "connection-speed", v),
        PROP_BUFFER_SIZE => back(s, "buffer-size", v),
        PROP_BUFFER_DURATION => back(s, "buffer-duration", v),
        PROP_AV_OFFSET => c.g_object_get_property(gobj(t.sink), "av-offset", v),
        PROP_TEXT_OFFSET => c.g_object_get_property(gobj(t.sink), "text-offset", v),
        PROP_RING_BUFFER_MAX_SIZE => back(s, "ring-buffer-max-size", v),
        PROP_FORCE_ASPECT_RATIO => {
            var b: c.gboolean = 0;
            c.g_object_get(gobj(t.sink), "force-aspect-ratio", &b, N);
            c.g_value_set_boolean(v, b);
        },
        PROP_MULTIVIEW_MODE => {
            cm.lock(s);
            c.g_value_set_enum(v, t.mv_mode);
            cm.unlock(s);
        },
        PROP_MULTIVIEW_FLAGS => {
            cm.lock(s);
            c.g_value_set_flags(v, t.mv_flags);
            cm.unlock(s);
        },
        PROP_INSTANT_URI => back(s, "instant-uri", v),
        else => cm.warnInvalid(FILE, o, id, spec, 1697),
    }
}

fn inList(l: [*c]c.GList, id: [*c]const u8) bool {
    var it = l;
    while (it != null) : (it = it.*.next) {
        if (c.g_strcmp0(@ptrCast(it.*.data), id) == 0) return true;
    }
    return false;
}

fn combineIndex(cb: *Combine, wanted: [*c]c.GList) c.gint {
    for (cb.streams.items, 0..) |x, i| {
        if (inList(wanted, c.gst_stream_get_stream_id(x))) return @intCast(i);
    }
    return -1;
}

fn extend(l: [*c]c.GList, stype: c.GstStreamType, col: *c.GstStreamCollection) [*c]c.GList {
    var res = l;
    const n = c.gst_stream_collection_get_size(col);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const x = c.gst_stream_collection_get_stream(col, i);
        if (c.gst_stream_get_stream_type(x) != stype) continue;
        const id = c.gst_stream_get_stream_id(x);
        if (!inList(res, id)) res = c.g_list_append(res, c.g_strdup(id));
    }
    return res;
}

fn rewriteSelect(s: *Self, ev: [*c]c.GstEvent) [*c]c.GstEvent {
    const t = st(s);
    if (t.customs[0] == null and t.customs[1] == null and t.customs[2] == null) return ev;
    const col = t.collection orelse return ev;
    var streams: [*c]c.GList = null;
    c.gst_event_parse_select_streams(ev, &streams);
    var use = c.g_list_copy_deep(streams, @ptrCast(&c.g_strdup), null);
    for ([_]Slot{ .audio, .video, .text }) |slot| {
        const i = @intFromEnum(slot);
        if (t.customs[i] == null) continue;
        use = extend(use, TYPES[i], col);
        const idx = combineIndex(&t.combine[i], streams);
        if (idx != -1) _ = setCurrent(s, slot, idx);
    }
    c.gst_event_unref(ev);
    const out = c.gst_event_new_select_streams(use);
    if (streams != null) c.g_list_free_full(streams, c.g_free);
    if (use != null) c.g_list_free_full(use, c.g_free);
    return out;
}

fn sendEvent(e: [*c]c.GstElement, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(e);
    const t = st(s);
    var ev = ev_in;
    if (cm.eventType(ev) == c.GST_EVENT_SELECT_STREAMS) {
        lock(s);
        t.do_selections = false;
        ev = rewriteSelect(s, ev);
        unlock(s);
        return c.gst_element_send_event(@ptrCast(@alignCast(t.collection_source)), ev);
    }
    if (cm.eventType(ev) & c.GST_EVENT_TYPE_UPSTREAM != 0) return c.gst_element_send_event(elem(t.sink), ev);
    return @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).send_event.?(e, ev);
}

fn doSelection(s: *Self) void {
    const t = st(s);
    const col = t.collection orelse return;
    const n = c.gst_stream_collection_get_size(col);
    var picked: [*c]c.GList = null;
    var count: [3]c.gint = .{ 0, 0, 0 };
    var chosen: c.GstStreamType = 0;
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const x = c.gst_stream_collection_get_stream(col, i);
        const stype = c.gst_stream_get_stream_type(x);
        const slot = slotOf(stype) orelse continue;
        const k = @intFromEnum(slot);
        const want = count[k] == t.current[k] or (t.current[k] == -1 and count[k] == 0) or t.customs[k] != null;
        count[k] += 1;
        if (!want) continue;
        if (t.do_selections) picked = c.g_list_append(picked, @constCast(c.gst_stream_get_stream_id(x)));
        chosen |= stype;
    }
    if (picked != null) {
        _ = c.gst_element_send_event(@ptrCast(@alignCast(t.collection_source)), c.gst_event_new_select_streams(picked));
        c.g_list_free(picked);
    }
    t.selected = chosen;
    if (t.active != t.selected) reconfigure(s);
}

fn handleMessage(b: [*c]c.GstBin, msg: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var reset = false;
    switch (msg.*.type) {
        c.GST_MESSAGE_STREAM_COLLECTION => {
            var col: ?*c.GstStreamCollection = null;
            c.gst_message_parse_stream_collection(msg, &col);
            if (col) |x| {
                const prev = t.do_selections;
                lock(s);
                _ = c.gst_object_replace(@ptrCast(&t.collection), @ptrCast(@alignCast(x)));
                _ = c.gst_object_replace(&t.collection_source, msg.*.src);
                updateCombiners(s, t.collection);
                if (prev) t.do_selections = false;
                doSelection(s);
                if (prev) t.do_selections = true;
                unlock(s);
                c.gst_object_unref(x);
            }
        },
        c.GST_MESSAGE_RESET_TIME => {
            if (t.is_live and elem(s).target_state == c.GST_STATE_PLAYING) reset = true;
        },
        c.GST_MESSAGE_STREAMS_SELECTED => {
            var types: c.GstStreamType = 0;
            lock(s);
            const n = c.gst_message_streams_selected_get_size(msg);
            var i: c.guint = 0;
            while (i < n) : (i += 1) {
                const x = c.gst_message_streams_selected_get_stream(msg, i);
                types |= c.gst_stream_get_stream_type(x);
                c.gst_object_unref(x);
            }
            t.selected = types;
            if (t.active != t.selected) reconfigure(s);
            unlock(s);
        },
        else => {},
    }
    parent_class.?.handle_message.?(b, msg);
    if (reset) _ = c.gst_element_change_state(elem(s), c.GST_STATE_CHANGE_PAUSED_TO_PLAYING);
}

fn deepAdded(b: [*c]c.GstBin, sub: [*c]c.GstBin, child: [*c]c.GstElement) callconv(.c) void {
    c.g_signal_emit(b, signals[SIG_ELEMENT_SETUP], 0, child);
    parent_class.?.deep_element_added.?(b, sub, child);
}

fn currentIndex(cb: *Combine) c.gint {
    if (!cb.has_active_pad) return -1;
    for (cb.inputs.items, 0..) |p, i| {
        const parent: *c.GObject = @ptrCast(@alignCast(c.gst_pad_get_parent(p) orelse continue));
        var cur: ?*c.GstPad = null;
        c.g_object_get(parent, "active-pad", &cur, N);
        c.gst_object_unref(parent);
        if (cur) |x| c.gst_object_unref(x);
        if (cur == p) return @intCast(i);
    }
    return -1;
}

fn activeChanged(combiner: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    lock(s);
    for (&t.combine, 0..) |*cb, i| {
        if (@as(?*c.GObject, @ptrCast(@alignCast(cb.combiner))) != combiner) continue;
        t.current[i] = currentIndex(cb);
        if (t.pending_flush[i]) {
            t.pending_flush[i] = false;
            unlock(s);
            _ = sendCustom(@ptrCast(@alignCast(combiner)), FLUSH_DONE[i]);
            return;
        }
        break;
    }
    unlock(s);
}

fn multiviewCaps(s: *Self, caps: [*c]c.GstCaps) [*c]c.GstCaps {
    const t = st(s);
    cm.lock(s);
    const mode = t.mv_mode;
    const mflags = t.mv_flags;
    cm.unlock(s);
    if (mode == c.GST_VIDEO_MULTIVIEW_MODE_NONE) return null;
    var cur_mode: c.gint = c.GST_VIDEO_MULTIVIEW_MODE_NONE;
    var cur_flags: c.guint = 0;
    const one = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_get_flagset(one, "multiview-flags", &cur_flags, null);
    const str = c.gst_structure_get_string(one, "multiview-mode");
    if (str != null) cur_mode = c.gst_video_multiview_mode_from_caps_string(str);
    if (cur_mode > c.GST_VIDEO_MULTIVIEW_MAX_FRAME_PACKING) return null;
    const out = c.gst_caps_copy(caps);
    c.gst_structure_set(c.gst_caps_get_structure(out, 0), "multiview-mode", c.G_TYPE_STRING, c.gst_video_multiview_mode_to_caps_string(mode), "multiview-flags", c.gst_video_multiview_flagset_get_type(), mflags, @as(c.guint, c.GST_FLAG_SET_MASK_EXACT), N);
    return out;
}

fn capsProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const ev: [*c]c.GstEvent = @ptrCast(@alignCast(info.*.data));
    if (cm.eventType(ev) != c.GST_EVENT_CAPS) return c.GST_PAD_PROBE_OK;
    var caps: [*c]c.GstCaps = null;
    c.gst_event_parse_caps(ev, &caps);
    const name = std.mem.span(c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0)));
    if (!std.mem.startsWith(u8, name, "video/")) return c.GST_PAD_PROBE_OK;
    const out = multiviewCaps(me(data), caps);
    if (out == null) return c.GST_PAD_PROBE_OK;
    c.gst_event_unref(ev);
    info.*.data = c.gst_event_new_caps(out);
    c.gst_caps_unref(out);
    return c.GST_PAD_PROBE_OK;
}

fn removeCombiner(s: *Self, cb: *Combine) void {
    const comb = cb.combiner orelse return;
    for (cb.inputs.items) |p| {
        c.gst_element_release_request_pad(comb, p);
        c.gst_object_unref(p);
    }
    cb.inputs.clearRetainingCapacity();
    _ = c.gst_element_set_state(comb, c.GST_STATE_NULL);
    _ = c.gst_bin_remove(binOf(s), comb);
    cb.combiner = null;
}

fn createCombiner(s: *Self, cb: *Combine) void {
    const t = st(s);
    if (cb.combiner != null) return;
    const slot = slotOf(cb.stype).?;
    cb.combiner = t.customs[@intFromEnum(slot)];
    const comb = cb.combiner orelse return;
    cb.srcpad = c.gst_element_get_static_pad(comb, "src");
    cb.has_active_pad = c.g_object_class_find_property(@ptrCast(@alignCast(gobj(comb).g_type_instance.g_class)), "active-pad") != null;
    if (cb.has_active_pad) _ = c.g_signal_connect_data(comb, "notify::active-pad", @ptrCast(&activeChanged), s, null, 0);
    _ = c.gst_bin_add(binOf(s), comb);
    _ = c.gst_element_sync_state_with_parent(comb);
}

fn controlPad(s: *Self, cb: *Combine, src: ?*c.GstPad) ?*c.GstPad {
    if (cb.combiner) |comb| {
        const sink = c.gst_element_request_pad_simple(comb, "sink_%u") orelse {
            coreError(s, c.g_strdup_printf("Failed to get request pad from combiner %p.", comb), "combiner_control_pad", 2364);
            return null;
        };
        cb.inputs.append(A, sink) catch @panic("oom");
        const res = c.gst_pad_link(src, sink);
        if (res < 0) {
            coreError(s, c.g_strdup_printf("Failed to link pad to combiner. Error %d", res), "combiner_control_pad", 2382);
            return null;
        }
        return sink;
    }
    if (c.gst_pad_is_linked(cb.sinkpad) != 0) {
        coreError(s, c.g_strdup("playsink pad already used !"), "combiner_control_pad", 2371);
        return null;
    }
    const res = c.gst_pad_link(src, cb.sinkpad);
    if (res != c.GST_PAD_LINK_OK) coreError(s, c.g_strdup_printf("Failed to link pad to sink. Error %d", res), "combiner_control_pad", 2376);
    return null;
}

fn findSource(s: *Self, pad: ?*c.GstPad) ?usize {
    for (st(s).sources.items, 0..) |x, i| if (x.pad == pad) return i;
    return null;
}

fn releaseSource(s: *Self, cb: *Combine, pad: ?*c.GstPad) void {
    const t = st(s);
    const i = findSource(s, pad) orelse return;
    const sp = t.sources.items[i];
    if (sp.probe != 0) c.gst_pad_remove_probe(pad, sp.probe);
    sp.probe = 0;
    if (sp.combine_sink) |x| {
        c.gst_element_release_request_pad(cb.combiner, x);
        for (cb.inputs.items, 0..) |p, j| if (p == x) {
            _ = cb.inputs.orderedRemove(j);
            c.gst_object_unref(p);
            break;
        };
    }
    _ = t.sources.orderedRemove(i);
    A.destroy(sp);
}

fn padAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    const name = c.gst_object_get_name(@ptrCast(@alignCast(pad)));
    const slot = slotOfName(name);
    c.g_free(name);
    const sl = slot orelse return;
    const k = @intFromEnum(sl);
    lock(s);
    const cb = &t.combine[k];
    const sel = t.selected | TYPES[k];
    if (sel != t.active) {
        t.selected = sel;
        reconfigure(s);
    }
    const cpad = controlPad(s, cb, pad);
    const sp = A.create(SourcePad) catch @panic("oom");
    sp.* = .{ .pad = pad, .stype = cb.stype, .combine_sink = cpad, .probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, capsProbe, s, null) };
    t.sources.append(A, sp) catch @panic("oom");
    unlock(s);
}

fn padRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    lock(s);
    defer unlock(s);
    const slot = slotOfName(cm.padName(pad)) orelse return;
    releaseSource(s, &st(s).combine[@intFromEnum(slot)], pad);
}

fn selectStream(_: ?*c.GstElement, _: ?*c.GstStreamCollection, stream: ?*c.GstStream, data: c.gpointer) callconv(.c) c.gint {
    const slot = slotOf(c.gst_stream_get_stream_type(stream)) orelse return -1;
    return if (st(data).customs[@intFromEnum(slot)] != null) 1 else -1;
}

fn reconfigure(s: *Self) void {
    const t = st(s);
    std.debug.assert(t.selected != t.active);
    lock(s);
    for (&t.combine, 0..) |*cb, i| {
        const sel = cb.stype & t.selected == cb.stype;
        const act = cb.stype & t.active == cb.stype;
        if (act and !sel) {
            if (cb.srcpad) |p| {
                if (cb.sinkpad != null) _ = c.gst_pad_unlink(p, cb.sinkpad);
                c.gst_object_unref(p);
                cb.srcpad = null;
            }
            if (cb.sinkpad) |p| {
                playsink.releasePad(ps(s), p);
                c.gst_object_unref(p);
                cb.sinkpad = null;
            }
            removeCombiner(s, cb);
        } else if (!act and sel and cb.sinkpad == null) {
            cb.sinkpad = playsink.requestPad(ps(s), KINDS[i]);
            _ = c.gst_object_ref(cb.sinkpad);
            createCombiner(s, cb);
            if (cb.combiner != null) {
                const res = c.gst_pad_link(cb.srcpad, cb.sinkpad);
                if (res != c.GST_PAD_LINK_OK) coreError(s, c.g_strdup_printf("Failed to link combiner to sink. Error %d", res), "reconfigure_output", 2629);
            }
        }
    }
    t.active = t.selected;
    unlock(s);
    _ = playsink.requestReconfigure(ps(s));
    asyncDone(s);
}

fn aboutToFinish(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit(data, signals[SIG_ABOUT_TO_FINISH], 0);
}

fn sourceSetup(_: ?*c.GstElement, source: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit(data, signals[SIG_SOURCE_SETUP], 0, source);
}

fn changeState(e: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    if (tr == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        lock(s);
        t.active = 0;
        t.selected = 0;
        asyncStart(s);
        unlock(s);
    }
    var ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, tr);
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        asyncDone(s);
        return ret;
    }
    switch (tr) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            if (ret == c.GST_STATE_CHANGE_SUCCESS) ret = c.GST_STATE_CHANGE_ASYNC;
        },
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => asyncDone(s),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            t.is_live = false;
            if (t.selected != 0) {
                t.selected = 0;
                reconfigure(s);
            }
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            for (t.sinks) |x| if (x) |y| {
                _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
            };
            for ([_]usize{ 1, 0, 2 }) |i| if (t.customs[i]) |y| {
                _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
            };
            _ = c.gst_object_replace(@ptrCast(&t.collection), null);
            _ = c.gst_object_replace(&t.collection_source, null);
        },
        else => {},
    }
    if ((tr & 0x7) == c.GST_STATE_PAUSED) t.is_live = ret == c.GST_STATE_CHANGE_NO_PREROLL;
    if (ret == c.GST_STATE_CHANGE_NO_PREROLL) asyncDone(s);
    return ret;
}

fn convertSample(s: ?*Self, caps: [*c]c.GstCaps) callconv(.c) ?*c.GstSample {
    var out: ?*c.GstSample = null;
    c.g_signal_emit_by_name(st(s.?).sink, "convert-sample", caps, &out);
    return out;
}

fn sinkOverlay(p: anytype) *c.GstVideoOverlay {
    return @ptrCast(@alignCast(st(p).sink));
}

fn ovExpose(o: ?*c.GstVideoOverlay) callconv(.c) void {
    c.gst_video_overlay_expose(sinkOverlay(o));
}

fn ovEvents(o: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    c.gst_video_overlay_handle_events(sinkOverlay(o), on);
}

fn ovRect(o: ?*c.GstVideoOverlay, x: c.gint, y: c.gint, w: c.gint, h: c.gint) callconv(.c) void {
    _ = c.gst_video_overlay_set_render_rectangle(sinkOverlay(o), x, y, w, h);
}

fn ovHandle(o: ?*c.GstVideoOverlay, handle: c.guintptr) callconv(.c) void {
    c.gst_video_overlay_set_window_handle(sinkOverlay(o), handle);
}

fn overlayInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(iface));
    i.expose = ovExpose;
    i.handle_events = ovEvents;
    i.set_render_rectangle = ovRect;
    i.set_window_handle = ovHandle;
}

fn navSend(n: ?*c.GstNavigation, ev: ?*c.GstEvent) callconv(.c) void {
    c.gst_navigation_send_event_simple(@ptrCast(@alignCast(st(n).sink)), ev);
}

fn navigationInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(iface));
    i.send_event_simple = navSend;
}

fn sinkBalance(p: anytype) *c.GstColorBalance {
    return @ptrCast(@alignCast(st(p).sink));
}

fn cbList(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    return c.gst_color_balance_list_channels(sinkBalance(b));
}

fn cbSet(b: ?*c.GstColorBalance, ch: ?*c.GstColorBalanceChannel, v: c.gint) callconv(.c) void {
    c.gst_color_balance_set_value(sinkBalance(b), ch, v);
}

fn cbGet(b: ?*c.GstColorBalance, ch: ?*c.GstColorBalanceChannel) callconv(.c) c.gint {
    return c.gst_color_balance_get_value(sinkBalance(b), ch);
}

fn cbType(b: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    return c.gst_color_balance_get_balance_type(sinkBalance(b));
}

fn balanceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstColorBalanceInterface = @ptrCast(@alignCast(iface));
    i.list_channels = cbList;
    i.set_value = cbSet;
    i.get_value = cbGet;
    i.get_balance_type = cbType;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = st(o);
    for (t.sinks) |x| if (x) |y| {
        _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
        c.gst_object_unref(y);
    };
    for ([_]usize{ 1, 0, 2 }) |i| if (t.customs[i]) |y| {
        _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
        c.gst_object_unref(y);
    };
    for (&t.combine) |*cb| {
        clearStreams(cb);
        cb.streams.deinit(A);
        for (cb.inputs.items) |p| c.gst_object_unref(p);
        cb.inputs.deinit(A);
    }
    for (t.sources.items) |x| A.destroy(x);
    t.sources.deinit(A);
    c.g_rec_mutex_clear(&t.lock);
    A.destroy(t);
    me(o).st = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const el = c.gst_element_get_type();
    c.g_object_class_install_property(oc, PROP_URI, c.g_param_spec_string("uri", "URI", "URI of the media to play", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_CURRENT_URI, c.g_param_spec_string("current-uri", "Current URI", "The currently playing URI", null, ro));
    c.g_object_class_install_property(oc, PROP_SUBURI, c.g_param_spec_string("suburi", ".sub-URI", "Optional URI of a subtitle", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_CURRENT_SUBURI, c.g_param_spec_string("current-suburi", "Current .sub-URI", "The currently playing URI of a subtitle", null, ro));
    c.g_object_class_install_property(oc, PROP_FLAGS, c.g_param_spec_flags("flags", "Flags", "Flags to control behaviour", flags.flagsType(), DEFAULT_FLAGS, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_FILTER, c.g_param_spec_object("video-filter", "Video filter", "the video filter(s) to apply, if possible", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_FILTER, c.g_param_spec_object("audio-filter", "Audio filter", "the audio filter(s) to apply, if possible", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_SINK, c.g_param_spec_object("video-sink", "Video Sink", "the video output element to use (NULL = default sink)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_SINK, c.g_param_spec_object("audio-sink", "Audio Sink", "the audio output element to use (NULL = default sink)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIS_PLUGIN, c.g_param_spec_object("vis-plugin", "Vis plugin", "the visualization element to use (NULL = default)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_SINK, c.g_param_spec_object("text-sink", "Text plugin", "the text output element to use (NULL = default subtitleoverlay)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_STREAM_COMBINER, c.g_param_spec_object("video-stream-combiner", "Video stream combiner", "Current video stream combiner (default: none)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_STREAM_COMBINER, c.g_param_spec_object("audio-stream-combiner", "Audio stream combiner", "Current audio stream combiner (default: none))", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_STREAM_COMBINER, c.g_param_spec_object("text-stream-combiner", "Text stream combiner", "Current text stream combiner (default: none)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VOLUME, c.g_param_spec_double("volume", "Volume", "The audio volume, 1.0=100%", 0.0, VOLUME_MAX, 1.0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MUTE, c.g_param_spec_boolean("mute", "Mute", "Mute the audio channel without changing the volume", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_SAMPLE, c.g_param_spec_boxed("sample", "Sample", "The last sample (NULL = no video available)", c.gst_sample_get_type(), ro));
    c.g_object_class_install_property(oc, PROP_FONT_DESC, c.g_param_spec_string("subtitle-font-desc", "Subtitle font description", "Pango font description of font to be used for subtitle rendering", null, c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_SIZE, c.g_param_spec_int("buffer-size", "Buffer size (bytes)", "Buffer size when buffering network streams", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_DURATION, c.g_param_spec_int64("buffer-duration", "Buffer duration (ns)", "Buffer duration when buffering network streams", -1, std.math.maxInt(i64), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_AV_OFFSET, c.g_param_spec_int64("av-offset", "AV Offset", "The synchronisation offset between audio and video in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_OFFSET, c.g_param_spec_int64("text-offset", "Text Offset", "The synchronisation offset between text and video in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_RING_BUFFER_MAX_SIZE, c.g_param_spec_uint64("ring-buffer-max-size", "Max. ring buffer size (bytes)", "Max. amount of data in the ring buffer (bytes, 0 = ring buffer disabled)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORCE_ASPECT_RATIO, c.g_param_spec_boolean("force-aspect-ratio", "Force Aspect Ratio", "When enabled, scaling will respect original aspect ratio", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_MULTIVIEW_MODE, c.g_param_spec_enum("video-multiview-mode", "Multiview Mode Override", "Re-interpret a video stream as one of several frame-packed stereoscopic modes.", c.gst_video_multiview_frame_packing_get_type(), c.GST_VIDEO_MULTIVIEW_FRAME_PACKING_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_MULTIVIEW_FLAGS, c.g_param_spec_flags("video-multiview-flags", "Multiview Flags Override", "Override details of the multiview frame layout", c.gst_video_multiview_flags_get_type(), c.GST_VIDEO_MULTIVIEW_FLAGS_NONE, cm.RW));
    c.g_object_class_install_property(oc, PROP_INSTANT_URI, c.g_param_spec_boolean("instant-uri", "Instantaneous URI change", "When enabled, URI changes are applied immediately", 0, cm.RW));
    const t = cm.typeOfClass(k);
    signals[SIG_ABOUT_TO_FINISH] = c.g_signal_new("about-to-finish", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "about_to_finish"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[SIG_SOURCE_SETUP] = c.g_signal_new("source-setup", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, el);
    signals[SIG_ELEMENT_SETUP] = c.g_signal_new("element-setup", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, el);
    _ = c.g_signal_new("convert-sample", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "convert_sample"), null, null, null, c.gst_sample_get_type(), 1, c.gst_caps_get_type());
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.convert_sample = convertSample;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Player Bin 3", "Generic/Bin/Player", "Autoplug and play media from an uri", "Wim Taymans <wim.taymans@gmail.com>");
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    bc.deep_element_added = deepAdded;
    _ = c._gst_debug_category_new("playbin3", 0, "play bin3");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    c.g_rec_mutex_init(&t.lock);
    t.udb = c.gst_element_factory_make("uridecodebin3", "uridecodebin3");
    c.g_object_set(gobj(t.udb), "use-buffering", @as(c.gboolean, 1), N);
    _ = c.gst_bin_add(binOf(s), t.udb);
    var caps: [*c]c.GstCaps = null;
    c.g_object_get(gobj(t.udb), "caps", &caps, N);
    caps = c.gst_caps_merge(caps, subtitleoverlay.factoryCaps());
    c.g_object_set(gobj(t.udb), "caps", caps, N);
    c.gst_caps_unref(caps);
    _ = c.g_signal_connect_data(t.udb, "pad-added", @ptrCast(&padAdded), s, null, 0);
    _ = c.g_signal_connect_data(t.udb, "pad-removed", @ptrCast(&padRemoved), s, null, 0);
    _ = c.g_signal_connect_data(t.udb, "select-stream", @ptrCast(&selectStream), s, null, 0);
    _ = c.g_signal_connect_data(t.udb, "source-setup", @ptrCast(&sourceSetup), s, null, 0);
    _ = c.g_signal_connect_data(t.udb, "about-to-finish", @ptrCast(&aboutToFinish), s, null, 0);
    t.sink = @ptrCast(@alignCast(c.g_object_new(playsink.getType(), "name", "playsink", "send-event-mode", @as(c.gint, 1), N)));
    _ = c.gst_bin_add(binOf(s), elem(t.sink));
    playsink.setFlags(ps(s), DEFAULT_FLAGS);
    _ = c.g_signal_connect_data(t.sink, "notify::volume", @ptrCast(&notifyVolume), s, null, 0);
    _ = c.g_signal_connect_data(t.sink, "notify::mute", @ptrCast(&notifyMute), s, null, 0);
    _ = c.g_signal_connect_data(t.sink, "value-changed", @ptrCast(&balanceChanged), s, null, 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_pipeline_get_type(), "GstPlayBin3", Class, Self, classInit, init);
            const none = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            const ov = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
            const nav = c.GInterfaceInfo{ .interface_init = navigationInit, .interface_finalize = null, .interface_data = null };
            const col = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_stream_volume_get_type(), &none);
            c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &ov);
            c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &nav);
            c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &col);
            return t;
        }
    }.f);
}
