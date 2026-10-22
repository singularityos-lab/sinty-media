const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const convertbin = @import("convertbin.zig");
const streamsynchronizer = @import("streamsynchronizer.zig");

const FILE = "../gst/playback/gstplaysink.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const RESET_MARK = "gst-playsink-reset-segment-event-marker";
const DEFAULT_FLAGS = flags.AUDIO | flags.VIDEO | flags.TEXT | flags.SOFT_VOLUME | flags.SOFT_COLORBALANCE;

pub const Kind = enum(u3) { audio, video, text, flushing };

const MODE_DEFAULT = 0;
const MODE_FIRST = 1;

const PROP_FLAGS = 1;
const PROP_MUTE = 2;
const PROP_VOLUME = 3;
const PROP_FONT_DESC = 4;
const PROP_SUBTITLE_ENCODING = 5;
const PROP_VIS_PLUGIN = 6;
const PROP_SAMPLE = 7;
const PROP_AV_OFFSET = 8;
const PROP_TEXT_OFFSET = 9;
const PROP_VIDEO_SINK = 10;
const PROP_AUDIO_SINK = 11;
const PROP_TEXT_SINK = 12;
const PROP_SEND_EVENT_MODE = 13;
const PROP_FORCE_ASPECT_RATIO = 14;
const PROP_VIDEO_FILTER = 15;
const PROP_AUDIO_FILTER = 16;

const Chain = struct {
    sink: *Self,
    bin: ?*c.GstElement = null,
    added: bool = false,
    activated: bool = false,
    raw: bool = false,
};

const AudioChain = struct {
    chain: Chain,
    sinkpad: ?*c.GstPad = null,
    queue: ?*c.GstElement = null,
    filter_conv: ?*c.GstElement = null,
    filter: ?*c.GstElement = null,
    conv: ?*c.GstElement = null,
    volume: ?*c.GstElement = null,
    sink_volume: bool = false,
    notify_volume: c.gulong = 0,
    notify_mute: c.gulong = 0,
    out: ?*c.GstElement = null,
    ts_offset: ?*c.GstElement = null,
};

const DeintChain = struct {
    chain: Chain,
    sinkpad: ?*c.GstPad = null,
    srcpad: ?*c.GstPad = null,
    conv: ?*c.GstElement = null,
    deinterlace: ?*c.GstElement = null,
};

const VideoChain = struct {
    chain: Chain,
    sinkpad: ?*c.GstPad = null,
    queue: ?*c.GstElement = null,
    filter_conv: ?*c.GstElement = null,
    filter: ?*c.GstElement = null,
    conv: ?*c.GstElement = null,
    out: ?*c.GstElement = null,
    async: bool = false,
    ts_offset: ?*c.GstElement = null,
};

const VisChain = struct {
    chain: Chain,
    sinkpad: ?*c.GstPad = null,
    queue: ?*c.GstElement = null,
    conv: ?*c.GstElement = null,
    resample: ?*c.GstElement = null,
    blockpad: ?*c.GstPad = null,
    peerpad: ?*c.GstPad = null,
    vissink: ?*c.GstPad = null,
    vis: ?*c.GstElement = null,
    vissrc: ?*c.GstPad = null,
    srcpad: ?*c.GstPad = null,
};

const TextChain = struct {
    chain: Chain,
    queue: ?*c.GstElement = null,
    identity: ?*c.GstElement = null,
    overlay: ?*c.GstElement = null,
    videosinkpad: ?*c.GstPad = null,
    textsinkpad: ?*c.GstPad = null,
    srcpad: ?*c.GstPad = null,
    out: ?*c.GstElement = null,
};

const Input = struct {
    pad: ?*c.GstPad = null,
    raw: bool = false,
    blocked: bool = false,
    block: c.gulong = 0,
    caps_id: c.gulong = 0,
    ssink: ?*c.GstPad = null,
    ssrc: ?*c.GstPad = null,
};

const State = struct {
    lock: c.GRecMutex = undefined,
    async_pending: bool = false,
    need_async_start: bool = false,
    reconfigure_pending: bool = false,
    flags: c.guint = DEFAULT_FLAGS,
    ssync: ?*c.GstElement = null,
    audio: ?*AudioChain = null,
    deint: ?*DeintChain = null,
    video: ?*VideoChain = null,
    visc: ?*VisChain = null,
    text: ?*TextChain = null,
    in: [3]Input = .{ .{}, .{}, .{} },
    ssync_queue: ?*c.GstElement = null,
    ssync_queue_sink: ?*c.GstPad = null,
    tee: ?*c.GstElement = null,
    tee_sink: ?*c.GstPad = null,
    tee_asrc: ?*c.GstPad = null,
    tee_vissrc: ?*c.GstPad = null,
    vis_block: c.gulong = 0,
    pending: u32 = 0,
    audio_sink: ?*c.GstElement = null,
    video_sink: ?*c.GstElement = null,
    audio_filter: ?*c.GstElement = null,
    video_filter: ?*c.GstElement = null,
    visualisation: ?*c.GstElement = null,
    text_sink: ?*c.GstElement = null,
    volume: f64 = 1.0,
    mute: bool = false,
    font_desc: [*c]u8 = null,
    sub_encoding: [*c]u8 = null,
    count: c.guint = 0,
    volume_changed: bool = false,
    mute_changed: bool = false,
    av_offset: i64 = 0,
    text_offset: i64 = 0,
    send_event_mode: c.gint = MODE_DEFAULT,
    force_aspect: bool = true,
    overlay: ?*c.GstElement = null,
    handle_set: bool = false,
    handle: c.guintptr = 0,
    rect_set: bool = false,
    rect: [4]c.gint = .{ 0, 0, 0, 0 },
    events_set: bool = false,
    events: bool = false,
    balance: ?*c.GstElement = null,
    channels: [*c]c.GList = null,
    values: [4]c.gint = .{ 0, 0, 0, 0 },
    balance_id: c.gulong = 0,
    text_flush_finished: bool = false,
    text_ignore_wrong: bool = false,
    text_pending_flush: bool = false,
};

pub const Self = extern struct {
    parent: c.GstBin,
    st: ?*State,
};

pub const Class = extern struct {
    parent: c.GstBinClass,
    reconfigure: ?*const fn (?*Self) callconv(.c) c.gboolean,
    convert_sample: ?*const fn (?*Self, [*c]c.GstCaps) callconv(.c) ?*c.GstSample,
};

var audio_raw_t = cm.staticTemplate("audio_raw_sink", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var audio_t = cm.staticTemplate("audio_sink", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var video_raw_t = cm.staticTemplate("video_raw_sink", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var video_t = cm.staticTemplate("video_sink", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");
var text_t = cm.staticTemplate("text_sink", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "ANY");

var once: cm.Once = .{};
var mode_once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;

const mode_values = [_]c.GEnumValue{
    .{ .value = MODE_DEFAULT, .value_name = "Default GstBin's send_event handling (default)", .value_nick = "default" },
    .{ .value = MODE_FIRST, .value_name = "Sends the event to sinks until the first one handles it", .value_nick = "first" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn modeType() c.GType {
    return mode_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstPlaySinkSendEventMode", &mode_values);
        }
    }.f);
}

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

fn ghost(p: ?*c.GstPad) ?*c.GstGhostPad {
    return @ptrCast(@alignCast(p));
}

fn gobj(p: anytype) *c.GObject {
    return @ptrCast(@alignCast(p));
}

fn ref(p: anytype) @TypeOf(p) {
    return @ptrCast(@alignCast(c.gst_object_ref(p)));
}

fn lock(s: *Self) void {
    c.g_rec_mutex_lock(&st(s).lock);
}

fn unlock(s: *Self) void {
    c.g_rec_mutex_unlock(&st(s).lock);
}

fn set(o: anytype, name: [*c]const u8, v: anytype) void {
    c.g_object_set(gobj(o), name, v, N);
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, s);
}

fn missingMsg(s: *Self, name: [*c]const u8) void {
    _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), name));
}

fn missingWarn(s: *Self, name: [*c]const u8, dbg: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    missingMsg(s, name);
    const text = c.g_strdup_printf(tr("Missing element '%s' - check your GStreamer installation."), name);
    cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, text, c.g_strdup(dbg), FILE, func, line);
}

fn missingErr(s: *Self, name: [*c]const u8, dbg: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    missingMsg(s, name);
    const text = c.g_strdup_printf(tr("Missing element '%s' - check your GStreamer installation."), name);
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, text, c.g_strdup(dbg), FILE, func, line);
}

fn coreError(s: *Self, code: c.gint, text: [*c]u8, dbg: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_core_error_quark(), code, text, c.g_strdup(dbg), FILE, func, line);
}

fn freeChain(ch: anytype) void {
    const p = ch orelse return;
    if (p.chain.bin) |b| c.gst_object_unref(b);
    A.destroy(p);
}

fn newChain(comptime T: type, s: *Self, raw: bool) *T {
    const p = A.create(T) catch @panic("oom");
    p.* = .{ .chain = .{ .sink = s, .raw = raw } };
    return p;
}

fn newBin(ch: *Chain, name: [*c]const u8) *c.GstBin {
    ch.bin = c.gst_bin_new(name);
    _ = c.gst_object_ref_sink(ch.bin);
    return binOf(ch.bin);
}

fn addChain(ch: *Chain, add: bool) void {
    if (ch.added == add) return;
    if (add) _ = c.gst_bin_add(binOf(ch.sink), ch.bin) else _ = c.gst_bin_remove(binOf(ch.sink), ch.bin);
    ch.added = add;
}

fn activateChain(ch: *Chain, on: bool) void {
    if (ch.activated == on) return;
    cm.lock(ch.sink);
    const target = elem(ch.sink).target_state;
    cm.unlock(ch.sink);
    _ = c.gst_element_set_state(ch.bin, if (on) target else c.GST_STATE_NULL);
    ch.activated = on;
}

fn isSink(e: *c.GstElement) bool {
    cm.lock(e);
    defer cm.unlock(e);
    return (cm.obj(e).flags & c.GST_ELEMENT_FLAG_SINK) != 0;
}

fn hasProp(e: *c.GstElement, name: [*c]const u8, t: c.GType) bool {
    const spec = c.g_object_class_find_property(@ptrCast(@alignCast(gobj(e).g_type_instance.g_class)), name) orelse return false;
    return t == c.G_TYPE_INVALID or spec.*.value_type == t or c.g_type_is_a(spec.*.value_type, t) != 0;
}

fn findInBin(b: *c.GstElement, name: [*c]const u8, t: c.GType, need_sink: bool) ?*c.GstElement {
    const it = c.gst_bin_iterate_recurse(binOf(b));
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const e = elem(c.g_value_get_object(&item));
                if ((!need_sink or isSink(e)) and hasProp(e, name, t)) return ref(e);
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return null,
        }
    }
}

fn findSinkProp(e: ?*c.GstElement, name: [*c]const u8, t: c.GType) ?*c.GstElement {
    const o = e orelse return null;
    if (hasProp(o, name, t)) return o;
    if (!cm.isA(@as(?*c.GstElement, o), c.gst_bin_get_type())) return null;
    const r = findInBin(o, name, t, true) orelse return null;
    c.gst_object_unref(r);
    return r;
}

fn findProp(e: *c.GstElement, name: [*c]const u8, t: c.GType) ?*c.GstElement {
    if (cm.isA(@as(?*c.GstElement, e), c.gst_bin_get_type())) return findInBin(e, name, t, false);
    if (hasProp(e, name, t)) return ref(e);
    return null;
}

fn findSinkPropRef(e: ?*c.GstElement, name: [*c]const u8, t: c.GType) ?*c.GstElement {
    const r = findSinkProp(e, name, t) orelse return null;
    return ref(r);
}

fn asyncStart(s: *Self) void {
    const t = st(s);
    if (!t.need_async_start) return;
    t.async_pending = true;
    parent_class.?.handle_message.?(binOf(s), c.gst_message_new_async_start(cm.obj(s)));
}

fn asyncDone(s: *Self) void {
    const t = st(s);
    if (t.async_pending) {
        parent_class.?.handle_message.?(binOf(s), c.gst_message_new_async_done(cm.obj(s), cm.CLOCK_NONE));
        t.async_pending = false;
    }
    t.need_async_start = false;
}

fn tryElement(s: *Self, e: ?*c.GstElement, unref: bool) ?*c.GstElement {
    const x = e orelse return null;
    c.gst_element_set_bus(x, binOf(s).child_bus);
    if (c.gst_element_set_state(x, c.GST_STATE_READY) != c.GST_STATE_CHANGE_FAILURE) return x;
    c.gst_element_set_bus(x, null);
    _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
    if (unref) c.gst_object_unref(x);
    return null;
}

fn link(a: ?*c.GstElement, ap: [*c]const u8, b: ?*c.GstElement, bp: [*c]const u8) bool {
    return c.gst_element_link_pads_full(a, ap, b, bp, c.GST_PAD_LINK_CHECK_TEMPLATE_CAPS) != 0;
}

fn linkPads(a: ?*c.GstPad, b: ?*c.GstPad) void {
    _ = c.gst_pad_link_full(a, b, c.GST_PAD_LINK_CHECK_NOTHING);
}

fn queueProps(q: ?*c.GstElement, time: u64) void {
    c.g_object_set(gobj(q), "max-size-buffers", @as(c.guint, 3), "max-size-bytes", @as(c.guint, 0), "max-size-time", time, "silent", @as(c.gboolean, 1), N);
}

fn ssyncPair(s: *Self, in: *Input) void {
    if (in.ssink != null) return;
    in.ssink = c.gst_element_request_pad_simple(st(s).ssync, "sink_%u");
    const it = c.gst_pad_iterate_internal_links(in.ssink);
    var item = std.mem.zeroes(c.GValue);
    _ = c.gst_iterator_next(it, &item);
    in.ssrc = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
}

fn ssyncRelease(s: *Self, in: *Input) bool {
    const p = in.ssink orelse return false;
    c.gst_element_release_request_pad(st(s).ssync, p);
    c.gst_object_unref(p);
    in.ssink = null;
    c.gst_object_unref(in.ssrc);
    in.ssrc = null;
    return true;
}

fn removeSsyncQueue(s: *Self) void {
    const t = st(s);
    const q = t.ssync_queue orelse return;
    _ = c.gst_element_set_state(q, c.GST_STATE_NULL);
    c.gst_object_unref(t.ssync_queue_sink);
    _ = c.gst_bin_remove(binOf(s), q);
    t.ssync_queue = null;
    t.ssync_queue_sink = null;
}

fn releaseTee(s: *Self, p: *?*c.GstPad) void {
    const x = p.* orelse return;
    c.gst_element_release_request_pad(st(s).tee, x);
    c.gst_object_unref(x);
    p.* = null;
}

fn disconnectAudio(ch: ?*AudioChain) void {
    const a = ch orelse return;
    if (a.notify_volume != 0) c.g_signal_handler_disconnect(a.volume, a.notify_volume);
    if (a.notify_mute != 0) c.g_signal_handler_disconnect(a.volume, a.notify_mute);
    a.notify_volume = 0;
    a.notify_mute = 0;
}

fn dropVolume(a: *AudioChain) void {
    if (a.volume) |v| c.gst_object_unref(v);
    a.volume = null;
}

fn dropOffset(p: *?*c.GstElement) void {
    if (p.*) |x| c.gst_object_unref(x);
    p.* = null;
}

fn replaceOffset(p: *?*c.GstElement, sink: ?*c.GstElement) void {
    const n = findSinkProp(sink, "ts-offset", c.G_TYPE_INT64);
    _ = c.gst_object_replace(@ptrCast(p), @ptrCast(n));
}

fn sinkSlot(t: *State, k: Kind) ?*?*c.GstElement {
    return switch (k) {
        .audio => &t.audio_sink,
        .video => &t.video_sink,
        .text => &t.text_sink,
        else => null,
    };
}

pub fn setSink(s: *Self, k: Kind, sink: ?*c.GstElement) void {
    lock(s);
    const slot = sinkSlot(st(s), k);
    var old: ?*c.GstElement = null;
    if (slot) |p| {
        old = p.*;
        if (sink) |x| _ = c.gst_object_ref_sink(x);
        p.* = sink;
    }
    unlock(s);
    if (sink != null and slot != null) {
        if (c.gst_element_get_static_pad(sink, "sink")) |p| {
            c.gst_object_unref(p);
        } else {
            const name: [*c]const u8 = switch (k) {
                .audio => "audio",
                .video => "video",
                else => "text",
            };
            cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, c.g_strdup("Application error - playback can't work"), c.g_strdup_printf("custom %s sink has no pad named \"sink\"", name), FILE, "gst_play_sink_set_sink", 927);
        }
    }
    if (old) |o| {
        if (o != sink and cm.obj(o).parent == null) _ = c.gst_element_set_state(o, c.GST_STATE_NULL);
        c.gst_object_unref(o);
    }
}

pub fn getSink(s: *Self, k: Kind) ?*c.GstElement {
    lock(s);
    defer unlock(s);
    const t = st(s);
    const chained: ?*c.GstElement = switch (k) {
        .audio => if (t.audio) |a| a.out else null,
        .video => if (t.video) |v| v.out else null,
        .text => if (t.text) |x| x.out else null,
        else => null,
    };
    if (chained) |x| return ref(x);
    const slot = sinkSlot(t, k) orelse return null;
    return if (slot.*) |x| ref(x) else null;
}

pub fn setFilter(s: *Self, k: Kind, filter: ?*c.GstElement) void {
    lock(s);
    const t = st(s);
    const slot: ?*?*c.GstElement = switch (k) {
        .audio => &t.audio_filter,
        .video => &t.video_filter,
        else => null,
    };
    var old: ?*c.GstElement = null;
    if (slot) |p| {
        old = p.*;
        if (filter) |x| _ = c.gst_object_ref_sink(x);
        p.* = filter;
    }
    unlock(s);
    if (old) |o| {
        if (o != filter and cm.obj(o).parent == null) _ = c.gst_element_set_state(o, c.GST_STATE_NULL);
        c.gst_object_unref(o);
    }
}

pub fn getFilter(s: *Self, k: Kind) ?*c.GstElement {
    lock(s);
    defer unlock(s);
    const t = st(s);
    const chained: ?*c.GstElement = switch (k) {
        .audio => if (t.audio) |a| a.filter else null,
        .video => if (t.video) |v| v.filter else null,
        else => null,
    };
    if (chained) |x| return ref(x);
    const own: ?*c.GstElement = switch (k) {
        .audio => t.audio_filter,
        .video => t.video_filter,
        else => null,
    };
    return if (own) |x| ref(x) else null;
}

fn swapVis(ch: *VisChain, vis: ?*c.GstElement) void {
    _ = c.gst_pad_unlink(ch.peerpad, ch.vissink);
    _ = c.gst_ghost_pad_set_target(ghost(ch.srcpad), null);
    _ = c.gst_element_set_state(ch.vis, c.GST_STATE_NULL);
    _ = c.gst_bin_remove(binOf(ch.chain.bin), ch.vis);
    ch.vis = vis;
    _ = c.gst_bin_add(binOf(ch.chain.bin), ch.vis);
    _ = c.gst_element_set_state(ch.vis, c.GST_STATE_PLAYING);
    ch.vissink = c.gst_element_get_static_pad(ch.vis, "sink");
    ch.vissrc = c.gst_element_get_static_pad(ch.vis, "src");
    linkPads(ch.peerpad, ch.vissink);
    _ = c.gst_ghost_pad_set_target(ghost(ch.srcpad), ch.vissrc);
}

fn visBlocked(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    if (cm.isEvent(info.*.data) and !cm.eventSerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
    lock(s);
    defer unlock(s);
    const t = st(s);
    if (t.visc) |ch| swapVis(ch, t.visualisation);
    t.vis_block = 0;
    return c.GST_PAD_PROBE_REMOVE;
}

pub fn setVisPlugin(s: *Self, vis_in: ?*c.GstElement) void {
    const vis = vis_in orelse c.gst_element_factory_make("goom", "vis") orelse return;
    lock(s);
    defer unlock(s);
    const t = st(s);
    if (t.visualisation) |o| c.gst_object_unref(o);
    _ = c.gst_object_ref_sink(vis);
    t.visualisation = vis;
    const ch = t.visc orelse return;
    if (t.vis_block == 0 and t.in[0].block == 0 and t.in[1].block == 0 and t.in[2].block == 0)
        t.vis_block = c.gst_pad_add_probe(ch.blockpad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, visBlocked, s, null);
}

pub fn getVisPlugin(s: *Self) ?*c.GstElement {
    lock(s);
    defer unlock(s);
    const t = st(s);
    if (t.visc) |ch| if (ch.vis) |v| return ref(v);
    return if (t.visualisation) |v| ref(v) else null;
}

pub fn setVolume(s: *Self, v: f64) void {
    lock(s);
    defer unlock(s);
    const t = st(s);
    t.volume = v;
    if (t.audio) |a| if (a.volume) |e| return set(e, "volume", v);
    t.volume_changed = true;
}

pub fn getVolume(s: *Self) f64 {
    lock(s);
    defer unlock(s);
    const t = st(s);
    if (t.audio) |a| if (a.volume) |e| {
        var v: f64 = 0;
        c.g_object_get(gobj(e), "volume", &v, N);
        t.volume = v;
    };
    return t.volume;
}

pub fn setMute(s: *Self, m: bool) void {
    lock(s);
    defer unlock(s);
    const t = st(s);
    t.mute = m;
    if (t.audio) |a| if (a.volume) |e| return set(e, "mute", @as(c.gboolean, @intFromBool(m)));
    t.mute_changed = true;
}

pub fn getMute(s: *Self) bool {
    lock(s);
    defer unlock(s);
    const t = st(s);
    if (t.audio) |a| if (a.volume) |e| {
        var v: c.gboolean = 0;
        c.g_object_get(gobj(e), "mute", &v, N);
        t.mute = v != 0;
    };
    return t.mute;
}

fn balanceOf(p: anytype) *c.GstColorBalance {
    return @ptrCast(@alignCast(p));
}

fn channelOf(p: c.gpointer) *c.GstColorBalanceChannel {
    return @ptrCast(@alignCast(p));
}

fn hasLabel(label: [*c]const u8, want: [*c]const u8) bool {
    return c.g_strrstr(label, want) != null;
}

fn validBalance(b: *c.GstColorBalance) bool {
    var got = [4]bool{ false, false, false, false };
    var l: ?*const c.GList = c.gst_color_balance_list_channels(b);
    while (l) |n| : (l = n.next) {
        const label = channelOf(n.data).label;
        if (hasLabel(label, "BRIGHTNESS")) got[0] = true else if (hasLabel(label, "CONTRAST")) got[1] = true else if (hasLabel(label, "HUE")) got[2] = true else if (hasLabel(label, "SATURATION")) got[3] = true;
    }
    return got[0] and got[1] and got[2] and got[3];
}

fn findBalance(e: *c.GstElement) ?*c.GstElement {
    if (cm.isA(@as(?*c.GstElement, e), c.gst_color_balance_get_type()) and validBalance(balanceOf(e))) return ref(e);
    if (!cm.isA(@as(?*c.GstElement, e), c.gst_bin_get_type())) return null;
    var best: ?*c.GstElement = null;
    const it = c.gst_bin_iterate_all_by_interface(binOf(e), c.gst_color_balance_get_type());
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const cb = elem(c.g_value_get_object(&item));
                if (validBalance(balanceOf(cb))) {
                    if (best) |b| {
                        if (c.gst_color_balance_get_balance_type(balanceOf(b)) == c.GST_COLOR_BALANCE_SOFTWARE) {
                            c.gst_object_unref(b);
                            best = ref(cb);
                        }
                    } else best = ref(cb);
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                if (best) |b| c.gst_object_unref(b);
                best = null;
                c.gst_iterator_resync(it);
            },
            else => break,
        }
    }
    c.g_value_unset(&item);
    return best;
}

fn scale(v: c.gint, from: *c.GstColorBalanceChannel, to: *c.GstColorBalanceChannel) c.gint {
    const f = (@as(f64, @floatFromInt(v)) - @as(f64, @floatFromInt(from.min_value))) / (@as(f64, @floatFromInt(from.max_value)) - @as(f64, @floatFromInt(from.min_value)));
    const r = @as(f64, @floatFromInt(to.min_value)) + f * (@as(f64, @floatFromInt(to.max_value)) - @as(f64, @floatFromInt(to.min_value)));
    return @intFromFloat(r + 0.5);
}

fn matchChannel(b: *c.GstColorBalance, proxy: *c.GstColorBalanceChannel) ?*c.GstColorBalanceChannel {
    var l: ?*const c.GList = c.gst_color_balance_list_channels(b);
    while (l) |n| : (l = n.next) {
        if (hasLabel(channelOf(n.data).label, proxy.label)) return channelOf(n.data);
    }
    return null;
}

fn balanceChanged(_: ?*c.GstColorBalance, ch: ?*c.GstColorBalanceChannel, value: c.gint, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    var i: usize = 0;
    var l = t.channels;
    while (l != null) : ({
        l = l.*.next;
        i += 1;
    }) {
        const proxy = channelOf(l.*.data);
        if (!hasLabel(ch.?.label, proxy.label)) continue;
        t.values[i] = scale(value, ch.?, proxy);
        c.gst_color_balance_value_changed(balanceOf(s), proxy, t.values[i]);
        break;
    }
}

fn updateBalance(s: *Self) void {
    const t = st(s);
    cm.lock(s);
    const b = if (t.balance) |x| ref(x) else null;
    cm.unlock(s);
    const bal = b orelse return;
    defer c.gst_object_unref(bal);
    c.g_signal_handler_block(bal, t.balance_id);
    var i: usize = 0;
    var l = t.channels;
    while (l != null) : ({
        l = l.*.next;
        i += 1;
    }) {
        const proxy = channelOf(l.*.data);
        const ch = matchChannel(balanceOf(bal), proxy) orelse continue;
        c.gst_color_balance_set_value(balanceOf(bal), ch, scale(t.values[i], proxy, ch));
    }
    c.g_signal_handler_unblock(bal, t.balance_id);
}

fn dropBalanceLocked(t: *State) void {
    if (t.balance) |b| {
        c.g_signal_handler_disconnect(b, t.balance_id);
        t.balance_id = 0;
        c.gst_object_unref(b);
    }
    t.balance = null;
}

fn takeBalance(s: *Self, b: ?*c.GstElement) void {
    const t = st(s);
    t.balance = b;
    if (b) |x| t.balance_id = c.g_signal_connect_data(x, "value-changed", @ptrCast(&balanceChanged), s, null, 0);
}

fn dropOverlayAndBalance(s: *Self) void {
    const t = st(s);
    cm.lock(s);
    if (t.overlay) |o| c.gst_object_unref(o);
    t.overlay = null;
    dropBalanceLocked(t);
    cm.unlock(s);
}

fn overlayOf(p: anytype) *c.GstVideoOverlay {
    return @ptrCast(@alignCast(p));
}

fn applyOverlay(s: *Self, o: *c.GstElement) void {
    const t = st(s);
    if (t.handle_set) c.gst_video_overlay_set_window_handle(overlayOf(o), t.handle);
    if (t.events_set) c.gst_video_overlay_handle_events(overlayOf(o), @intFromBool(t.events));
    if (t.rect_set) _ = c.gst_video_overlay_set_render_rectangle(overlayOf(o), t.rect[0], t.rect[1], t.rect[2], t.rect[3]);
}

fn grabOverlay(s: *Self, b: ?*c.GstElement) void {
    const t = st(s);
    cm.lock(s);
    if (t.overlay) |o| c.gst_object_unref(o);
    t.overlay = c.gst_bin_get_by_interface(binOf(b), c.gst_video_overlay_get_type());
    const o = if (t.overlay) |x| ref(x) else null;
    cm.unlock(s);
    if (o) |x| {
        applyOverlay(s, x);
        c.gst_object_unref(x);
    }
}

fn setAsync(v: *VideoChain, a: bool) void {
    if (findSinkProp(v.out, "async", c.G_TYPE_BOOLEAN)) |e| {
        set(e, "async", @as(c.gboolean, @intFromBool(a)));
        v.async = a;
    } else v.async = true;
}

fn setAspect(s: *Self, sink: ?*c.GstElement) void {
    if (findSinkProp(sink, "force-aspect-ratio", c.G_TYPE_BOOLEAN)) |e| set(e, "force-aspect-ratio", @as(c.gboolean, @intFromBool(st(s).force_aspect)));
}

fn genDeint(s: *Self) ?*DeintChain {
    const ch = newChain(DeintChain, s, false);
    const b = newBin(&ch.chain, "vdbin");
    var head: ?*c.GstElement = null;
    var prev: ?*c.GstElement = null;
    ch.conv = c.gst_element_factory_make("videoconvert", "vdconv");
    if (ch.conv == null) {
        missingWarn(s, "videoconvert", "video rendering might fail", "gen_video_deinterlace_chain", 1529);
    } else {
        _ = c.gst_bin_add(b, ch.conv);
        head = ch.conv;
        prev = ch.conv;
    }
    ch.deinterlace = c.gst_element_factory_make("deinterlace", "deinterlace");
    if (ch.deinterlace == null) {
        missingWarn(s, "deinterlace", "deinterlacing won't work", "gen_video_deinterlace_chain", 1542);
    } else {
        _ = c.gst_bin_add(b, ch.deinterlace);
        if (prev != null) {
            if (!link(prev, "src", ch.deinterlace, "sink")) {
                coreError(s, c.GST_CORE_ERROR_PAD, null, "Failed to configure the video deinterlace chain.", "gen_video_deinterlace_chain", 1580);
                freeChain(@as(?*DeintChain, ch));
                return null;
            }
        } else head = ch.deinterlace;
        prev = ch.deinterlace;
    }
    if (head) |h| {
        const p = c.gst_element_get_static_pad(h, "sink");
        ch.sinkpad = c.gst_ghost_pad_new("sink", p);
        c.gst_object_unref(p);
    } else ch.sinkpad = c.gst_ghost_pad_new_no_target("sink", c.GST_PAD_SINK);
    if (prev) |p0| {
        const p = c.gst_element_get_static_pad(p0, "src");
        ch.srcpad = c.gst_ghost_pad_new("src", p);
        c.gst_object_unref(p);
    } else ch.srcpad = c.gst_ghost_pad_new("src", ch.sinkpad);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.sinkpad);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.srcpad);
    return ch;
}

const Media = struct {
    kind: Kind,
    auto: [*c]const u8,
    name: [*c]const u8,
    func: []const u8,
};

fn pickSink(s: *Self, configured: *?*c.GstElement, auto: [*c]const u8, name: [*c]const u8, made: *?*c.GstElement) ?*c.GstElement {
    if (configured.*) |x| return tryElement(s, x, false);
    made.* = c.gst_element_factory_make(auto, name);
    const r = tryElement(s, made.*, true);
    if (r) |x| configured.* = ref(x);
    return r;
}

fn noSinks(s: *Self, made: ?*c.GstElement, configured: ?*c.GstElement, audio: bool, comptime func: []const u8, lines: [3]c.gint) void {
    if (made == null and configured == null) {
        missingMsg(s, if (audio) "autoaudiosink" else "autovideosink");
        const text = c.g_strdup(tr(if (audio) "The autoaudiosink element is missing." else "The autovideosink element is missing."));
        coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, text, null, func, lines[0]);
    } else if (configured) |x| {
        const text = c.g_strdup_printf(tr(if (audio) "Configured audiosink %s is not working." else "Configured videosink %s is not working."), cm.obj(x).name);
        coreError(s, c.GST_CORE_ERROR_STATE_CHANGE, text, null, func, lines[1]);
    } else {
        const text = c.g_strdup(tr(if (audio) "The autoaudiosink element is not working." else "The autovideosink element is not working."));
        coreError(s, c.GST_CORE_ERROR_STATE_CHANGE, text, null, func, lines[2]);
    }
}

fn addFilter(s: *Self, b: *c.GstBin, filter: *?*c.GstElement, conv: *?*c.GstElement, raw: bool, audio: bool, head: *?*c.GstElement, prev: *?*c.GstElement, comptime func: []const u8, line: c.gint) enum { ok, link, nonraw } {
    filter.* = getFilter(s, if (audio) .audio else .video);
    const f = filter.* orelse return .ok;
    if (!raw) {
        c.gst_object_unref(f);
        filter.* = null;
        return if ((st(s).flags & flags.FORCE_FILTERS) != 0) .nonraw else .ok;
    }
    const factory: [*c]const u8 = if (audio) "audioconvert" else "videoconvert";
    conv.* = c.gst_element_factory_make(factory, "filter-convert");
    if (conv.* == null) {
        missingWarn(s, factory, if (audio) "audio playback and visualizations might not work" else "video playback and visualizations might not work", func, line);
    } else {
        _ = c.gst_bin_add(b, conv.*);
        head.* = conv.*;
        prev.* = conv.*;
    }
    _ = c.gst_bin_add(b, f);
    c.gst_object_unref(f);
    if (prev.* != null) {
        if (!link(prev.*, "src", f, null)) return .link;
    } else head.* = f;
    prev.* = f;
    return .ok;
}

fn chainTo(b: ?*c.GstElement, prev: *?*c.GstElement, head: *?*c.GstElement, e: ?*c.GstElement) bool {
    _ = c.gst_bin_add(binOf(b), e);
    if (prev.* != null) {
        if (!link(prev.*, "src", e, "sink")) return false;
    } else head.* = e;
    prev.* = e;
    return true;
}

fn genVideo(s: *Self, raw: bool, async: bool) ?*VideoChain {
    const t = st(s);
    const ch = newChain(VideoChain, s, raw);
    var made: ?*c.GstElement = null;
    ch.out = pickSink(s, &t.video_sink, "autovideosink", "videosink", &made);
    if (ch.out == null) {
        noSinks(s, made, t.video_sink, false, "gen_video_chain", .{ 2013, 2018, 2026 });
        freeChain(@as(?*VideoChain, ch));
        return null;
    }
    setAsync(ch, async);
    setAspect(s, ch.out);
    replaceOffset(&ch.ts_offset, ch.out);
    const b = newBin(&ch.chain, "vbin");
    _ = c.gst_bin_add(b, ch.out);
    grabOverlay(s, ch.chain.bin);
    var head = ch.out;
    var prev: ?*c.GstElement = null;
    var failed: ?c.gint = null;
    switch (addFilter(s, b, &ch.filter, &ch.filter_conv, raw, false, &head, &prev, "gen_video_chain", 1878)) {
        .ok => {},
        .link => failed = 2036,
        .nonraw => failed = 2042,
    }
    if (failed == null) {
        ch.queue = c.gst_element_factory_make("queue", "vqueue");
        if (ch.queue == null) {
            missingWarn(s, "queue", "video rendering might be suboptimal", "gen_video_chain", 1910);
        } else {
            queueProps(ch.queue, 0);
            if (!chainTo(ch.chain.bin, &prev, &head, ch.queue)) failed = 2036;
        }
    }
    if (failed == null) {
        cm.lock(s);
        dropBalanceLocked(t);
        takeBalance(s, findBalance(ch.out.?));
        cm.unlock(s);
        const native = (t.flags & flags.NATIVE_VIDEO) != 0;
        const soft = t.balance == null and (t.flags & flags.SOFT_COLORBALANCE) != 0;
        if (!native or soft) {
            ch.conv = elem(c.g_object_new(convertbin.videoType(), "name", "vconv", "use-converters", @as(c.gboolean, @intFromBool(!native)), "use-balance", @as(c.gboolean, @intFromBool(soft)), N));
            cm.lock(s);
            const vb = @as(*convertbin.Video, @ptrCast(@alignCast(ch.conv))).balance;
            if (soft and vb != null) takeBalance(s, ref(vb.?));
            cm.unlock(s);
            if (!chainTo(ch.chain.bin, &prev, &head, ch.conv)) failed = 2036;
        }
    }
    if (failed == null) {
        updateBalance(s);
        if (prev != null and !link(prev, "src", ch.out, null)) failed = 2036;
    }
    if (failed) |line| {
        if (line == 2042) {
            coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, "Cannot apply video-filter on non-raw stream", "gen_video_chain", 2042);
        } else coreError(s, c.GST_CORE_ERROR_PAD, null, "Failed to configure the video sink.", "gen_video_chain", 2036);
        _ = c.gst_element_set_state(ch.out, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(b, ch.out);
        freeChain(@as(?*VideoChain, ch));
        return null;
    }
    const p = c.gst_element_get_static_pad(head, "sink");
    ch.sinkpad = c.gst_ghost_pad_new("sink", p);
    c.gst_object_unref(p);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.sinkpad);
    return ch;
}

fn setupVideo(s: *Self, raw: bool, async: bool) bool {
    const t = st(s);
    const ch = t.video.?;
    if (ch.filter != null and ch.chain.raw != raw) return false;
    ch.chain.raw = raw;
    if (ch.chain.activated) return true;
    if (c.gst_element_set_state(ch.out, c.GST_STATE_READY) == c.GST_STATE_CHANGE_FAILURE) return false;
    grabOverlay(s, ch.chain.bin);
    replaceOffset(&ch.ts_offset, ch.out);
    setAsync(ch, async);
    setAspect(s, ch.out);
    cm.lock(s);
    dropBalanceLocked(t);
    takeBalance(s, findBalance(ch.out.?));
    cm.unlock(s);
    if (ch.conv) |conv| {
        const soft = t.balance == null and (t.flags & flags.SOFT_COLORBALANCE) != 0;
        set(conv, "use-balance", @as(c.gboolean, @intFromBool(soft)));
        cm.lock(s);
        const vb = @as(*convertbin.Video, @ptrCast(@alignCast(conv))).balance;
        if (soft and vb != null) takeBalance(s, ref(vb.?));
        cm.unlock(s);
    }
    updateBalance(s);
    return true;
}

fn customFlushEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev: ?*c.GstEvent) callconv(.c) c.gboolean {
    const s = me(c.gst_object_get_parent(parent));
    const t = st(s);
    const sct = c.gst_event_get_structure(ev);
    if (cm.eventType(ev) == c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB and sct != null) {
        const name = std.mem.span(c.gst_structure_get_name(sct));
        if (std.mem.eql(u8, name, "playsink-custom-subtitle-flush")) {
            lock(s);
            t.text_ignore_wrong = true;
            t.text_flush_finished = false;
            unlock(s);
        } else if (std.mem.eql(u8, name, "playsink-custom-subtitle-flush-finish")) {
            lock(s);
            t.text_pending_flush = true;
            t.text_flush_finished = true;
            unlock(s);
        }
    }
    const r = c.gst_pad_event_default(pad, parent, c.gst_event_ref(ev));
    c.gst_event_unref(ev);
    c.gst_object_unref(s);
    return r;
}

fn markEvent(e: ?*c.GstEvent, seq: ?*c.GstEvent) ?*c.GstEvent {
    if (seq) |x| c.gst_event_set_seqnum(e, c.gst_event_get_seqnum(x));
    c.gst_structure_set(c.gst_event_writable_structure(e), RESET_MARK, c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
    return e;
}

fn customFlushChain(pad: ?*c.GstPad, parent: ?*c.GstObject, buffer: ?*c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(c.gst_object_get_parent(parent));
    defer c.gst_object_unref(s);
    const t = st(s);
    lock(s);
    if (t.text_pending_flush) {
        t.text_pending_flush = false;
        unlock(s);
        const seg = c.gst_pad_get_sticky_event(pad, c.GST_EVENT_SEGMENT, 0);
        _ = c.gst_pad_send_event(pad, markEvent(c.gst_event_new_flush_start(), seg));
        _ = c.gst_pad_send_event(pad, markEvent(c.gst_event_new_flush_stop(1), seg));
        if (seg) |x| {
            _ = c.gst_pad_send_event(pad, markEvent(@ptrCast(c.gst_mini_object_copy(@ptrCast(x))), null));
            c.gst_event_unref(x);
        }
    } else unlock(s);
    var r = c.gst_proxy_pad_chain_default(pad, parent, buffer);
    lock(s);
    if (r == c.GST_FLOW_FLUSHING and t.text_ignore_wrong) {
        if (t.text_flush_finished) t.text_ignore_wrong = false;
        r = c.GST_FLOW_OK;
    }
    unlock(s);
    return r;
}

fn textSrcEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, ev: ?*c.GstEvent) callconv(.c) c.gboolean {
    defer c.gst_event_unref(ev);
    const sct = c.gst_event_get_structure(ev);
    if (sct != null and c.gst_structure_has_field(sct, RESET_MARK) != 0) return 1;
    return c.gst_pad_event_default(pad, parent, c.gst_event_ref(ev));
}

fn genText(s: *Self) *TextChain {
    const t = st(s);
    const ch = newChain(TextChain, s, false);
    const b = newBin(&ch.chain, "tbin");
    var vsink: ?*c.GstPad = null;
    var tsink: ?*c.GstPad = null;
    var src: ?*c.GstPad = null;
    if (t.text_sink) |custom| {
        ch.out = tryElement(s, custom, false);
        if (ch.out) |out| {
            if (findSinkProp(out, "async", c.G_TYPE_BOOLEAN)) |e| {
                set(e, "async", @as(c.gboolean, 0));
                _ = c.gst_bin_add(b, out);
                ch.queue = c.gst_element_factory_make("queue", "subqueue");
                if (ch.queue == null) {
                    missingWarn(s, "queue", "rendering might be suboptimal", "gen_text_chain", 2494);
                } else {
                    queueProps(ch.queue, c.GST_SECOND);
                    _ = c.gst_bin_add(b, ch.queue);
                }
                if (link(ch.queue, "src", out, "sink")) {
                    tsink = c.gst_element_get_static_pad(ch.queue, "sink");
                } else {
                    _ = c.gst_bin_remove(b, out);
                    _ = c.gst_bin_remove(b, ch.queue);
                    ch.out = null;
                    ch.queue = null;
                }
                if (ch.out != null) {
                    if (findSinkProp(ch.out, "sync", c.G_TYPE_BOOLEAN)) |y| set(y, "sync", @as(c.gboolean, 1));
                }
                if (tsink == null and ch.out != null) _ = c.gst_bin_remove(b, ch.out);
            }
        }
        if (tsink == null) cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup(tr("Custom text sink element is not usable.")), c.g_strdup("fallback to default subtitleoverlay"), FILE, "gen_text_chain", 2531);
    }
    if (tsink == null and (t.flags & flags.NATIVE_VIDEO) == 0) {
        ch.queue = c.gst_element_factory_make("queue", "vqueue");
        if (ch.queue == null) {
            missingWarn(s, "queue", "video rendering might be suboptimal", "gen_text_chain", 2543);
        } else {
            queueProps(ch.queue, 0);
            _ = c.gst_bin_add(b, ch.queue);
            vsink = c.gst_element_get_static_pad(ch.queue, "sink");
        }
        ch.overlay = c.gst_element_factory_make("subtitleoverlay", "suboverlay");
        if (ch.overlay == null) {
            missingWarn(s, "subtitleoverlay", "subtitle rendering disabled", "gen_text_chain", 2558);
        } else {
            _ = c.gst_bin_add(b, ch.overlay);
            set(ch.overlay, "silent", @as(c.gboolean, 0));
            if (t.font_desc != null) set(ch.overlay, "font-desc", t.font_desc);
            if (t.sub_encoding != null) set(ch.overlay, "subtitle-encoding", t.sub_encoding);
            _ = link(ch.queue, "src", ch.overlay, "video_sink");
            const q = c.gst_element_factory_make("queue", "subqueue");
            if (q == null) {
                missingWarn(s, "queue", "rendering might be suboptimal", "gen_text_chain", 2583);
            } else {
                queueProps(q, c.GST_SECOND);
                _ = c.gst_bin_add(b, q);
                if (link(q, "src", ch.overlay, "subtitle_sink")) {
                    tsink = c.gst_element_get_static_pad(q, "sink");
                    src = c.gst_element_get_static_pad(ch.overlay, "src");
                } else {
                    _ = c.gst_bin_remove(b, ch.out);
                    _ = c.gst_bin_remove(b, ch.overlay);
                    ch.out = null;
                    ch.overlay = null;
                    c.gst_object_unref(vsink);
                    vsink = null;
                }
            }
        }
    }
    if (vsink == null) {
        ch.identity = c.gst_element_factory_make("identity", "tidentity");
        if (ch.identity == null) {
            missingErr(s, "identity", null, "gen_text_chain", 2615);
        } else {
            set(ch.identity, "signal-handoffs", @as(c.gboolean, 0));
            set(ch.identity, "silent", @as(c.gboolean, 1));
            _ = c.gst_bin_add(b, ch.identity);
            src = c.gst_element_get_static_pad(ch.identity, "src");
            vsink = c.gst_element_get_static_pad(ch.identity, "sink");
        }
    }
    if (vsink) |p| {
        ch.videosinkpad = c.gst_ghost_pad_new("sink", p);
        c.gst_object_unref(p);
        _ = c.gst_element_add_pad(ch.chain.bin, ch.videosinkpad);
    }
    if (tsink) |p| {
        ch.textsinkpad = c.gst_ghost_pad_new("text_sink", p);
        c.gst_object_unref(p);
        c.gst_pad_set_event_function_full(ch.textsinkpad, customFlushEvent, null, null);
        c.gst_pad_set_chain_function_full(ch.textsinkpad, customFlushChain, null, null);
        _ = c.gst_element_add_pad(ch.chain.bin, ch.textsinkpad);
    }
    if (src) |p| {
        ch.srcpad = c.gst_ghost_pad_new("src", p);
        c.gst_object_unref(p);
        c.gst_pad_set_event_function_full(ch.srcpad, textSrcEvent, null, null);
        _ = c.gst_element_add_pad(ch.chain.bin, ch.srcpad);
    }
    return ch;
}

fn notifyVolume(o: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    var v: f64 = 0;
    c.g_object_get(o, "volume", &v, N);
    st(data).volume = v;
    c.g_object_notify(gobj(data), "volume");
}

fn notifyMute(o: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    var v: c.gboolean = 0;
    c.g_object_get(o, "mute", &v, N);
    st(data).mute = v != 0;
    c.g_object_notify(gobj(data), "mute");
}

fn watchVolume(s: *Self, a: *AudioChain) void {
    a.notify_volume = c.g_signal_connect_data(a.volume, "notify::volume", @ptrCast(&notifyVolume), s, null, 0);
    a.notify_mute = c.g_signal_connect_data(a.volume, "notify::mute", @ptrCast(&notifyMute), s, null, 0);
}

fn sinkVolume(sink: ?*c.GstElement) ?*c.GstElement {
    if (cm.isA(sink, c.gst_bin_get_type())) return c.gst_bin_get_by_interface(binOf(sink), c.gst_stream_volume_get_type());
    if (cm.isA(sink, c.gst_stream_volume_get_type())) return ref(sink.?);
    return null;
}

fn softVolume(s: *Self, a: *AudioChain) void {
    const t = st(s);
    c.g_object_get(gobj(a.conv), "volume-element", &a.volume, N);
    if (a.volume == null) return;
    watchVolume(s, a);
    set(a.volume, "volume", t.volume);
    set(a.volume, "mute", @as(c.gboolean, @intFromBool(t.mute)));
}

fn genAudio(s: *Self, raw: bool) ?*AudioChain {
    const t = st(s);
    const ch = newChain(AudioChain, s, raw);
    var made: ?*c.GstElement = null;
    ch.out = pickSink(s, &t.audio_sink, "autoaudiosink", "audiosink", &made);
    if (ch.out == null) {
        noSinks(s, made, t.audio_sink, true, "gen_audio_chain", .{ 2940, 2945, 2953 });
        freeChain(@as(?*AudioChain, ch));
        return null;
    }
    const b = newBin(&ch.chain, "abin");
    _ = c.gst_bin_add(b, ch.out);
    var head = ch.out;
    var prev: ?*c.GstElement = null;
    var failed: ?c.gint = null;
    switch (addFilter(s, b, &ch.filter, &ch.filter_conv, raw, true, &head, &prev, "gen_audio_chain", 2762)) {
        .ok => {},
        .link => failed = 2962,
        .nonraw => failed = 2968,
    }
    var have_volume = false;
    if (failed == null) {
        ch.queue = c.gst_element_factory_make("queue", "aqueue");
        if (ch.queue == null) {
            missingWarn(s, "queue", "audio playback and visualizations might not work", "gen_audio_chain", 2793);
        } else {
            set(ch.queue, "silent", @as(c.gboolean, 1));
            if (!chainTo(ch.chain.bin, &prev, &head, ch.queue)) failed = 2962;
        }
    }
    if (failed == null) {
        replaceOffset(&ch.ts_offset, ch.out);
        if (sinkVolume(ch.out)) |v| {
            ch.volume = v;
            have_volume = true;
            ch.sink_volume = true;
            watchVolume(s, ch);
            if (t.volume_changed) {
                set(v, "volume", t.volume);
                t.volume_changed = false;
            }
            if (t.mute_changed) {
                set(v, "mute", @as(c.gboolean, @intFromBool(t.mute)));
                t.mute_changed = false;
            }
        }
        const native = (t.flags & flags.NATIVE_AUDIO) != 0;
        const soft = !have_volume and (t.flags & flags.SOFT_VOLUME) != 0;
        if (!native or soft) {
            ch.conv = elem(c.g_object_new(convertbin.audioType(), "name", "aconv", "use-converters", @as(c.gboolean, @intFromBool(!native)), "use-volume", @as(c.gboolean, @intFromBool(soft)), N));
            if (!chainTo(ch.chain.bin, &prev, &head, ch.conv)) failed = 2962;
            if (failed == null and soft) {
                softVolume(s, ch);
                if (ch.volume != null) have_volume = true;
            }
        }
    }
    if (failed == null and prev != null and !link(prev, "src", ch.out, null)) failed = 2962;
    if (failed) |line| {
        if (line == 2968) {
            coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, "Cannot apply video-filter on non-raw stream", "gen_audio_chain", 2968);
        } else coreError(s, c.GST_CORE_ERROR_PAD, null, "Failed to configure the audio sink.", "gen_audio_chain", 2962);
        _ = c.gst_element_set_state(ch.out, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(b, ch.out);
        freeChain(@as(?*AudioChain, ch));
        return null;
    }
    if (!have_volume) cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_NOT_IMPLEMENTED, c.g_strdup(tr("No volume control found")), c.g_strdup("Volume/mute is not available"), FILE, "gen_audio_chain", 2906);
    const p = c.gst_element_get_static_pad(head, "sink");
    ch.sinkpad = c.gst_ghost_pad_new("sink", p);
    c.gst_object_unref(p);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.sinkpad);
    return ch;
}

fn setupAudio(s: *Self, raw: bool) bool {
    const t = st(s);
    const ch = t.audio.?;
    if (ch.filter != null and ch.chain.raw != raw) return false;
    ch.chain.raw = raw;
    if (ch.chain.activated) return true;
    if (c.gst_element_set_state(ch.out, c.GST_STATE_READY) == c.GST_STATE_CHANGE_FAILURE) return false;
    replaceOffset(&ch.ts_offset, ch.out);
    disconnectAudio(ch);
    dropVolume(ch);
    if (sinkVolume(ch.out)) |v| {
        ch.volume = v;
        if (t.volume_changed) {
            set(v, "volume", t.volume);
            t.volume_changed = false;
        }
        watchVolume(s, ch);
        set(v, "mute", @as(c.gboolean, @intFromBool(t.mute)));
        t.mute_changed = false;
        set(ch.conv, "use-volume", @as(c.gboolean, 0));
    } else if (ch.conv) |conv| {
        const soft = (t.flags & flags.SOFT_VOLUME) != 0;
        set(conv, "use-volume", @as(c.gboolean, @intFromBool(soft)));
        if (soft) softVolume(s, ch);
    }
    return true;
}

fn genVis(s: *Self) ?*VisChain {
    const t = st(s);
    const ch = newChain(VisChain, s, false);
    const b = newBin(&ch.chain, "visbin");
    ch.queue = c.gst_element_factory_make("queue", "visqueue");
    if (ch.queue == null) return visFail(s, ch, "queue", null, 3172);
    set(ch.queue, "silent", @as(c.gboolean, 1));
    _ = c.gst_bin_add(b, ch.queue);
    ch.conv = c.gst_element_factory_make("audioconvert", "aconv");
    if (ch.conv == null) return visFail(s, ch, "audioconvert", "make sure audioconvert isn't blacklisted", 3181);
    _ = c.gst_bin_add(b, ch.conv);
    ch.resample = c.gst_element_factory_make("audioresample", "aresample");
    if (ch.resample == null) return visFail(s, ch, "audioresample", null, 3190);
    _ = c.gst_bin_add(b, ch.resample);
    ch.blockpad = c.gst_element_get_static_pad(ch.queue, "src");
    ch.peerpad = c.gst_element_get_static_pad(ch.resample, "src");
    if (t.visualisation) |v| ch.vis = tryElement(s, v, false);
    if (ch.vis == null) {
        const e = c.gst_element_factory_make("goom", "vis");
        ch.vis = tryElement(s, e, true);
        _ = c.gst_object_replace(@ptrCast(&t.visualisation), @ptrCast(e));
    }
    if (ch.vis == null) return visFail(s, ch, "goom", null, 3199);
    _ = c.gst_bin_add(b, ch.vis);
    var ok = c.gst_element_link_pads_full(ch.queue, "src", ch.conv, "sink", c.GST_PAD_LINK_CHECK_NOTHING) != 0;
    ok = (c.gst_element_link_pads_full(ch.conv, "src", ch.resample, "sink", c.GST_PAD_LINK_CHECK_NOTHING) != 0) and ok;
    ok = (c.gst_element_link_pads_full(ch.resample, "src", ch.vis, "sink", c.GST_PAD_LINK_CHECK_NOTHING) != 0) and ok;
    if (!ok) {
        coreError(s, c.GST_CORE_ERROR_PAD, null, "Failed to configure the visualisation element.", "gen_vis_chain", 3207);
        _ = c.gst_element_set_state(ch.vis, c.GST_STATE_NULL);
        freeChain(@as(?*VisChain, ch));
        return null;
    }
    ch.vissink = c.gst_element_get_static_pad(ch.vis, "sink");
    ch.vissrc = c.gst_element_get_static_pad(ch.vis, "src");
    const p = c.gst_element_get_static_pad(ch.queue, "sink");
    ch.sinkpad = c.gst_ghost_pad_new("sink", p);
    c.gst_object_unref(p);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.sinkpad);
    ch.srcpad = c.gst_ghost_pad_new("src", ch.vissrc);
    _ = c.gst_element_add_pad(ch.chain.bin, ch.srcpad);
    return ch;
}

fn visFail(s: *Self, ch: *VisChain, name: [*c]const u8, dbg: [*c]const u8, line: c.gint) ?*VisChain {
    missingErr(s, name, dbg, "gen_vis_chain", line);
    freeChain(@as(?*VisChain, ch));
    return null;
}

fn isRawStructure(sct: ?*const c.GstStructure) bool {
    const n = std.mem.span(c.gst_structure_get_name(sct));
    return std.mem.eql(u8, n, "video/x-raw") or std.mem.eql(u8, n, "audio/x-raw");
}

fn isRawPad(pad: ?*c.GstPad) bool {
    const peer = c.gst_pad_get_peer(pad) orelse return true;
    defer c.gst_object_unref(peer);
    var raw = true;
    var caps = c.gst_pad_get_current_caps(peer);
    if (caps == null) {
        caps = c.gst_pad_query_caps(peer, null);
        var i: c.guint = 0;
        while (i < c.gst_caps_get_size(caps)) : (i += 1) {
            const r = isRawStructure(c.gst_caps_get_structure(caps, i));
            if (i == 0) {
                raw = r;
            } else if (raw != r) {
                raw = false;
                break;
            }
        }
    } else raw = isRawStructure(c.gst_caps_get_structure(caps, 0));
    c.gst_caps_unref(caps);
    return raw;
}

fn dropVideoChain(s: *Self) void {
    const t = st(s);
    const v = t.video.?;
    _ = ssyncRelease(s, &t.in[1]);
    addChain(&v.chain, false);
    if (v.out) |o| {
        if (o != t.video_sink) _ = c.gst_element_set_state(o, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(v.chain.bin), o);
    }
    if (v.filter) |f| {
        if (f != t.video_filter) _ = c.gst_element_set_state(f, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(v.chain.bin), f);
    }
    activateChain(&v.chain, false);
    freeChain(t.video);
    t.video = null;
    dropOverlayAndBalance(s);
}

fn dropAudioChain(s: *Self) void {
    const t = st(s);
    const a = t.audio.?;
    releaseTee(s, &t.tee_asrc);
    if (ssyncRelease(s, &t.in[0])) removeSsyncQueue(s);
    addChain(&a.chain, false);
    if (a.out) |o| {
        if (o != t.audio_sink) _ = c.gst_element_set_state(o, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(a.chain.bin), o);
    }
    if (a.filter) |f| {
        if (f != t.audio_filter) _ = c.gst_element_set_state(f, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(a.chain.bin), f);
    }
    activateChain(&a.chain, false);
    disconnectAudio(a);
    dropVolume(a);
    dropOffset(&a.ts_offset);
    freeChain(t.audio);
    t.audio = null;
    t.volume_changed = false;
    t.mute_changed = false;
}

fn relinkVideo(s: *Self, deint: bool) void {
    const t = st(s);
    const v = t.video.?;
    const old = c.gst_pad_get_peer(v.sinkpad);
    defer if (old) |x| c.gst_object_unref(x);
    const new = if (deint) t.deint.?.srcpad else t.in[1].ssrc;
    if (old == new) return;
    if (c.gst_pad_get_peer(new)) |x| {
        _ = c.gst_pad_unlink(new, x);
        c.gst_object_unref(x);
    }
    if (old) |x| _ = c.gst_pad_unlink(x, v.sinkpad);
    _ = c.gst_pad_link_full(new, v.sinkpad, c.GST_PAD_LINK_CHECK_NOTHING);
}

fn doReconfigure(s: *Self) bool {
    const t = st(s);
    lock(s);
    defer unlock(s);
    cm.lock(s);
    const fl = t.flags;
    cm.unlock(s);
    const a_in = &t.in[0];
    const v_in = &t.in[1];
    const t_in = &t.in[2];
    var need_text = (fl & flags.TEXT) != 0 and t_in.pad != null;
    var need_video = false;
    var need_audio = false;
    var need_deint = false;
    var need_vis = false;
    if (v_in.pad != null) v_in.raw = isRawPad(v_in.pad);
    if (a_in.pad != null) a_in.raw = isRawPad(a_in.pad);
    if ((fl & (flags.VIDEO | flags.NATIVE_VIDEO)) != 0 and v_in.pad != null) {
        need_video = true;
        need_deint = (fl & flags.DEINTERLACE) != 0 and (fl & flags.NATIVE_VIDEO) == 0 and v_in.raw;
    }
    if (a_in.pad != null) {
        if ((fl & (flags.AUDIO | flags.NATIVE_AUDIO)) != 0) need_audio = true;
        if (a_in.raw and (fl & flags.VIS) != 0 and !need_video) {
            need_video = true;
            need_vis = true;
        }
    }
    if (need_text and !need_video and t.text_sink == null) {
        const text = c.g_strdup(tr("Can't play a text file without video or visualizations."));
        const dbg = c.g_strdup("Have text pad but no video pad or visualizations");
        if (v_in.pad != null) {
            need_video = true;
            c.g_free(text);
            c.g_free(dbg);
        } else if (need_audio) {
            cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, text, dbg, FILE, "gst_play_sink_do_reconfigure", 3288);
            need_text = false;
        } else {
            cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, text, dbg, FILE, "gst_play_sink_do_reconfigure", 3293);
            return false;
        }
    }

    if (need_video) {
        const raw = need_vis or v_in.raw;
        const async = !need_vis;
        if (t.video) |v| {
            if ((t.video_sink != null and t.video_sink != v.out) or (t.video_filter != null and t.video_filter != v.filter) or !setupVideo(s, raw, async)) dropVideoChain(s);
        }
        if (t.video == null) t.video = genVideo(s, raw, async);
        const v = t.video orelse return false;
        ssyncPair(s, v_in);
        if (v_in.pad != null) _ = c.gst_ghost_pad_set_target(ghost(v_in.pad), v_in.ssink);
        if (need_deint) {
            if (t.deint == null) t.deint = genDeint(s);
            const d = t.deint orelse return false;
            addChain(&d.chain, true);
            activateChain(&d.chain, true);
            _ = c.gst_pad_unlink(v_in.ssrc, v.sinkpad);
            linkPads(v_in.ssrc, d.sinkpad);
        } else if (t.deint) |d| {
            addChain(&d.chain, false);
            activateChain(&d.chain, false);
        }
        addChain(&v.chain, true);
        activateChain(&v.chain, true);
        if (!need_vis and !need_text and (t.text == null or t_in.pad == null)) relinkVideo(s, need_deint);
    } else {
        if (t.video) |v| {
            if (t.visc) |vc| {
                releaseTee(s, &t.tee_vissrc);
                const p = c.gst_element_get_static_pad(vc.chain.bin, "src");
                _ = c.gst_pad_unlink(p, v.sinkpad);
            }
            _ = ssyncRelease(s, v_in);
            addChain(&v.chain, false);
            activateChain(&v.chain, false);
            dropOffset(&v.ts_offset);
        }
        if (t.deint) |d| {
            addChain(&d.chain, false);
            activateChain(&d.chain, false);
        }
        if (v_in.pad != null) _ = c.gst_ghost_pad_set_target(ghost(v_in.pad), null);
        dropOverlayAndBalance(s);
        if (t.video_sink) |x| _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
        if (t.video_filter) |x| _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
    }

    if (need_audio) {
        const raw = a_in.raw;
        if (t.audio) |a| {
            if ((t.audio_sink != null and t.audio_sink != a.out) or (t.audio_filter != null and t.audio_filter != a.filter) or !setupAudio(s, raw)) dropAudioChain(s);
        }
        if (t.audio == null) t.audio = genAudio(s, raw);
        const a = t.audio orelse return false;
        ssyncPair(s, a_in);
        if (need_vis) {
            if (c.gst_pad_get_peer(a_in.ssink)) |peer| {
                _ = c.gst_pad_unlink(peer, a_in.ssink);
                c.gst_object_unref(peer);
            }
            if (t.ssync_queue == null) {
                t.ssync_queue = c.gst_element_factory_make("queue", "audiossyncqueue");
                if (t.ssync_queue == null) missingWarn(s, "queue", "audio playback and visualizations might not work", "gst_play_sink_do_reconfigure", 3649);
                set(t.ssync_queue, "max-size-buffers", @as(c.guint, 1));
                _ = c.gst_bin_add(binOf(s), t.ssync_queue);
                t.ssync_queue_sink = c.gst_element_get_static_pad(t.ssync_queue, "sink");
            }
            const qsrc = c.gst_element_get_static_pad(t.ssync_queue, "src");
            linkPads(qsrc, a_in.ssink);
            c.gst_object_unref(qsrc);
            _ = c.gst_element_sync_state_with_parent(t.ssync_queue);
        }
        if (t.tee_asrc == null) t.tee_asrc = c.gst_element_request_pad_simple(t.tee, "src_%u");
        const sinkpad = t.ssync_queue_sink orelse a_in.ssink;
        addChain(&a.chain, true);
        activateChain(&a.chain, true);
        linkPads(t.tee_asrc, sinkpad);
        linkPads(a_in.ssrc, a.sinkpad);
    } else {
        if (t.audio) |a| {
            releaseTee(s, &t.tee_asrc);
            if (ssyncRelease(s, a_in)) removeSsyncQueue(s);
            if (a.sink_volume) {
                disconnectAudio(a);
                dropVolume(a);
                dropOffset(&a.ts_offset);
            }
            addChain(&a.chain, false);
            activateChain(&a.chain, false);
        }
        if (t.audio_sink) |x| _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
        if (t.audio_filter) |x| _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
    }

    if (need_vis) {
        if (t.visc == null) t.visc = genVis(s);
        if (t.visc) |vc| {
            if (!vc.chain.added) {
                const src = c.gst_element_get_static_pad(vc.chain.bin, "src");
                addChain(&vc.chain, true);
                activateChain(&vc.chain, true);
                if (t.tee_vissrc == null) t.tee_vissrc = c.gst_element_request_pad_simple(t.tee, "src_%u");
                linkPads(t.tee_vissrc, vc.sinkpad);
                linkPads(src, v_in.ssink);
                linkPads(v_in.ssrc, t.video.?.sinkpad);
                c.gst_object_unref(src);
            }
            if (vc.vis != t.visualisation) swapVis(vc, t.visualisation);
        }
    } else if (t.visc) |vc| {
        releaseTee(s, &t.tee_vissrc);
        addChain(&vc.chain, false);
        activateChain(&vc.chain, false);
    }

    if (need_text) {
        if (t.text == null) t.text = genText(s);
        const x = t.text.?;
        if (x.overlay) |o| set(o, "silent", @as(c.gboolean, 0));
        addChain(&x.chain, true);
        ssyncPair(s, t_in);
        _ = c.gst_ghost_pad_set_target(ghost(t_in.pad), t_in.ssink);
        linkPads(t_in.ssrc, x.textsinkpad);
        if (need_vis or need_video) {
            const v = t.video.?;
            if (need_vis) {
                const src = c.gst_element_get_static_pad(t.visc.?.chain.bin, "src");
                _ = c.gst_pad_unlink(src, v.sinkpad);
                linkPads(src, x.videosinkpad);
                c.gst_object_unref(src);
            } else {
                const from = if (need_deint) t.deint.?.srcpad else v_in.ssrc;
                _ = c.gst_pad_unlink(from, v.sinkpad);
                linkPads(from, x.videosinkpad);
            }
            linkPads(x.srcpad, v.sinkpad);
        }
        activateChain(&x.chain, true);
    } else if (t.text) |x| {
        if (t_in.pad == null) {
            addChain(&x.chain, false);
            activateChain(&x.chain, false);
            _ = ssyncRelease(s, t_in);
            if (!need_video and v_in.pad != null) {
                _ = ssyncRelease(s, v_in);
                _ = c.gst_ghost_pad_set_target(ghost(v_in.pad), null);
            }
            if (t.text_sink) |y| _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
        } else if (x.overlay) |o| set(o, "silent", @as(c.gboolean, 1));
    }
    updateAvOffset(s);
    updateTextOffset(s);
    asyncDone(s);
    t.reconfigure_pending = false;
    return true;
}

pub fn setFlags(s: *Self, f: c.guint) void {
    cm.lock(s);
    st(s).flags = f;
    cm.unlock(s);
}

pub fn getFlags(s: *Self) c.guint {
    cm.lock(s);
    defer cm.unlock(s);
    return st(s).flags;
}

fn setText(s: *Self, slot: *[*c]u8, prop: [*c]const u8, v: [*c]const u8) void {
    lock(s);
    defer unlock(s);
    c.g_free(slot.*);
    slot.* = c.g_strdup(v);
    if (st(s).text) |x| if (x.overlay) |o| set(o, prop, v);
}

fn getText(s: *Self, slot: *[*c]u8, prop: [*c]const u8) [*c]u8 {
    lock(s);
    defer unlock(s);
    if (st(s).text) |x| if (x.overlay) |o| {
        var r: [*c]u8 = null;
        c.g_object_get(gobj(o), prop, &r, N);
        slot.* = c.g_strdup(r);
        return r;
    };
    return c.g_strdup(slot.*);
}

fn updateAvOffset(s: *Self) void {
    const t = st(s);
    const a = t.audio orelse return;
    const v = t.video orelse return;
    const ao = a.ts_offset orelse return;
    const vo = v.ts_offset orelse return;
    set(ao, "ts-offset", @as(i64, @max(@as(i64, 0), -%t.av_offset)));
    set(vo, "ts-offset", @as(i64, @max(@as(i64, 0), t.av_offset)));
}

fn updateTextOffset(s: *Self) void {
    const t = st(s);
    const x = t.text orelse return;
    if (x.out != null) {
        if (findSinkProp(x.out, "ts-offset", c.G_TYPE_INT64)) |e| set(e, "ts-offset", t.text_offset);
    } else if (x.overlay) |o| set(o, "subtitle-ts-offset", t.text_offset);
}

pub fn lastSample(s: *Self) ?*c.GstSample {
    lock(s);
    defer unlock(s);
    const v = st(s).video orelse return null;
    if (!v.chain.activated) return null;
    const out = v.out orelse return null;
    const e = findProp(out, "last-sample", c.gst_sample_get_type()) orelse return null;
    defer c.gst_object_unref(e);
    var r: ?*c.GstSample = null;
    c.g_object_get(gobj(e), "last-sample", &r, N);
    return r;
}

fn convertSample(s: ?*Self, caps: [*c]c.GstCaps) callconv(.c) ?*c.GstSample {
    var r = lastSample(s.?);
    if (r != null and caps != null) {
        var err: [*c]c.GError = null;
        const tmp = c.gst_video_convert_sample(r, caps, 25 * c.GST_SECOND, &err);
        if (tmp == null and err != null) {
            c.gst_sample_unref(r);
            c.g_error_free(err);
            return null;
        }
        c.gst_sample_unref(r);
        r = tmp;
    }
    return r;
}

fn internal(p: ?*c.GstPad) ?*c.GstPad {
    return @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(p)))));
}

fn clearVisBlock(t: *State) void {
    if (t.vis_block != 0) c.gst_pad_remove_probe(t.visc.?.blockpad, t.vis_block);
    t.vis_block = 0;
}

fn setBlocked(s: *Self, k: Kind, on: bool) void {
    const t = st(s);
    const in = &t.in[@intFromEnum(k)];
    const pad = in.pad orelse return;
    const opad = internal(pad);
    defer c.gst_object_unref(opad);
    if (on and in.block == 0) {
        clearVisBlock(t);
        in.block = c.gst_pad_add_probe(opad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, padBlocked, s, null);
    } else if (!on and in.block != 0) {
        if (k == .audio) clearVisBlock(t);
        c.gst_pad_remove_probe(opad, in.block);
        t.pending &= ~(@as(u32, 1) << @intFromEnum(k));
        in.block = 0;
        in.blocked = false;
    }
}

fn unblockAll(s: *Self) void {
    setBlocked(s, .video, false);
    setBlocked(s, .audio, false);
    setBlocked(s, .text, false);
}

fn reconfigure(s: ?*Self) callconv(.c) c.gboolean {
    const x = s.?;
    lock(x);
    setBlocked(x, .video, true);
    setBlocked(x, .audio, true);
    setBlocked(x, .text, true);
    st(x).reconfigure_pending = true;
    unlock(x);
    return 1;
}

pub fn requestReconfigure(s: *Self) bool {
    return reconfigure(s) != 0;
}

fn readyLocked(t: *State) bool {
    if (!t.reconfigure_pending) return false;
    for (t.in, 0..) |in, i| {
        if (in.pad != null and !in.blocked and (t.pending & (@as(u32, 1) << @intCast(i))) != 0) return false;
    }
    return true;
}

fn padBlocked(blocked: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    if (cm.isEvent(info.*.data) and !cm.eventSerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
    lock(s);
    defer unlock(s);
    const t = st(s);
    const pad = internal(blocked);
    defer c.gst_object_unref(pad);
    for (&t.in) |*in| {
        if (pad == in.pad) {
            in.blocked = true;
            break;
        }
    }
    if (readyLocked(t)) {
        _ = doReconfigure(s);
        unblockAll(s);
    }
    return c.GST_PAD_PROBE_OK;
}

fn capsNotify(pad: ?*c.GstPad, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    var caps: [*c]c.GstCaps = null;
    c.g_object_get(gobj(pad), "caps", &caps, N);
    if (caps == null) return;
    var again = false;
    if (pad == t.in[0].pad) {
        again = t.in[0].raw != isRawPad(pad) and t.audio != null;
    } else if (pad == t.in[1].pad) {
        again = t.in[1].raw != isRawPad(pad) and t.video != null;
    }
    c.gst_caps_unref(caps);
    if (again) _ = reconfigure(s);
}

fn addBlock(s: *Self, pad: ?*c.GstPad, k: Kind) void {
    const t = st(s);
    const in = &t.in[@intFromEnum(k)];
    if (in.block != 0) return;
    const bp = internal(pad);
    clearVisBlock(t);
    in.block = c.gst_pad_add_probe(bp, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, padBlocked, s, null);
    t.pending |= @as(u32, 1) << @intFromEnum(k);
    c.gst_object_unref(bp);
}

pub fn refreshPad(s: *Self, pad: ?*c.GstPad, k: Kind) void {
    lock(s);
    defer unlock(s);
    const t = st(s);
    var which: ?Kind = null;
    for (t.in, 0..) |in, i| {
        if (pad == in.pad) which = @enumFromInt(i);
    }
    const w = which orelse return;
    if (w != k) return;
    addBlock(s, pad, k);
}

pub fn requestPad(s: *Self, k: Kind) ?*c.GstPad {
    const t = st(s);
    var res: ?*c.GstPad = null;
    var created = false;
    lock(s);
    switch (k) {
        .audio => {
            if (t.tee == null) {
                t.tee = c.gst_element_factory_make("tee", "audiotee");
                if (t.tee == null) {
                    missingErr(s, "tee", null, "gst_play_sink_request_pad", 4578);
                    unlock(s);
                    return null;
                }
                t.tee_sink = c.gst_element_get_static_pad(t.tee, "sink");
                _ = c.gst_bin_add(binOf(s), t.tee);
            }
            _ = c.gst_element_set_state(t.tee, c.GST_STATE_PAUSED);
            if (t.in[0].pad == null) {
                t.in[0].pad = c.gst_ghost_pad_new("audio_sink", t.tee_sink);
                t.in[0].caps_id = c.g_signal_connect_data(t.in[0].pad, "notify::caps", @ptrCast(&capsNotify), s, null, 0);
                created = true;
            }
            t.in[0].raw = false;
            res = t.in[0].pad;
        },
        .video => {
            if (t.in[1].pad == null) {
                t.in[1].pad = c.gst_ghost_pad_new_no_target("video_sink", c.GST_PAD_SINK);
                t.in[1].caps_id = c.g_signal_connect_data(t.in[1].pad, "notify::caps", @ptrCast(&capsNotify), s, null, 0);
                created = true;
            }
            t.in[1].raw = false;
            res = t.in[1].pad;
        },
        .text => {
            if (t.in[2].pad == null) {
                t.in[2].pad = c.gst_ghost_pad_new_no_target("text_sink", c.GST_PAD_SINK);
                created = true;
            }
            res = t.in[2].pad;
        },
        .flushing => {
            const name = c.g_strdup_printf("flushing_%u", t.count);
            res = c.gst_ghost_pad_new_no_target(name, c.GST_PAD_SINK);
            c.g_free(name);
            t.count += 1;
            created = true;
        },
    }
    unlock(s);
    if (created and res != null) {
        _ = c.gst_pad_set_active(res, 1);
        _ = c.gst_element_add_pad(elem(s), res);
        lock(s);
        if (k != .flushing) addBlock(s, res, k);
        unlock(s);
        if (k == .flushing) _ = c.gst_pad_set_active(res, 0);
    }
    return res;
}

fn requestNewPad(e: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, _: [*c]const c.gchar, _: ?*const c.GstCaps) callconv(.c) ?*c.GstPad {
    if (!cm.that(templ != null, "gst_play_sink_request_new_pad", "templ != NULL")) return null;
    const name = std.mem.span(templ.*.name_template);
    const k: Kind = if (std.mem.eql(u8, name, "audio_sink") or std.mem.eql(u8, name, "audio_raw_sink"))
        .audio
    else if (std.mem.eql(u8, name, "video_sink") or std.mem.eql(u8, name, "video_raw_sink"))
        .video
    else if (std.mem.eql(u8, name, "text_sink"))
        .text
    else
        return null;
    return requestPad(me(e), k);
}

pub fn releasePad(s: *Self, pad: ?*c.GstPad) void {
    const t = st(s);
    var slot: ?*?*c.GstPad = null;
    lock(s);
    for (&t.in, 0..) |*in, i| {
        if (pad != in.pad) continue;
        slot = &in.pad;
        if (in.caps_id != 0) c.g_signal_handler_disconnect(in.pad, in.caps_id);
        in.caps_id = 0;
        setBlocked(s, @enumFromInt(i), false);
        break;
    }
    unlock(s);
    var p: ?*c.GstPad = if (slot) |x| x.* else pad;
    if (p) |x| {
        _ = c.gst_pad_set_active(x, 0);
        if (slot != null) _ = c.gst_ghost_pad_set_target(ghost(x), null);
        _ = c.gst_element_remove_pad(elem(s), x);
        if (slot) |y| y.* = null;
        p = null;
    }
    lock(s);
    if (readyLocked(t)) {
        _ = doReconfigure(s);
        unblockAll(s);
    }
    unlock(s);
}

fn releaseRequestPad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    releasePad(me(e), pad);
}

fn handleMessage(b: [*c]c.GstBin, msg: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    switch (msg.*.type) {
        c.GST_MESSAGE_STEP_DONE => {
            var format: c.GstFormat = 0;
            var amount: u64 = 0;
            var rate: f64 = 0;
            var flush: c.gboolean = 0;
            var inter: c.gboolean = 0;
            var dur: u64 = 0;
            var eos: c.gboolean = 0;
            c.gst_message_parse_step_done(msg, &format, &amount, &rate, &flush, &inter, &dur, &eos);
            if (format == c.GST_FORMAT_BUFFERS) {
                if (t.audio) |a| {
                    if (c.gst_object_has_as_ancestor(msg.*.src, cm.obj(a.chain.bin)) == 0)
                        _ = c.gst_element_send_event(a.chain.bin, c.gst_event_new_step(c.GST_FORMAT_TIME, dur, rate, flush, inter));
                }
            }
            parent_class.?.handle_message.?(b, msg);
        },
        c.GST_MESSAGE_ELEMENT => {
            if (c.gst_is_video_overlay_prepare_window_handle_message(msg) == 0) return parent_class.?.handle_message.?(b, msg);
            cm.lock(s);
            if (t.overlay) |o| {
                if (cm.obj(o) != msg.*.src) {
                    c.gst_object_unref(o);
                    t.overlay = null;
                }
            }
            if (t.overlay == null) t.overlay = elem(c.gst_object_ref(msg.*.src));
            const o = ref(t.overlay.?);
            cm.unlock(s);
            applyOverlay(s, t.overlay.?);
            c.gst_object_unref(o);
            c.gst_message_unref(msg);
            c.gst_video_overlay_prepare_window_handle(overlayOf(s));
        },
        else => parent_class.?.handle_message.?(b, msg),
    }
}

fn sendToSink(s: *Self, ev: ?*c.GstEvent, force_video: bool) c.gboolean {
    const t = st(s);
    if (t.send_event_mode != MODE_FIRST and !force_video) return parentElement().send_event.?(elem(s), ev);
    var r: c.gboolean = 1;
    defer c.gst_event_unref(ev);
    if (t.text) |x| if (x.out != null) {
        r = c.gst_element_send_event(x.chain.bin, c.gst_event_ref(ev));
    };
    if (t.video) |v| {
        r = c.gst_element_send_event(v.chain.bin, c.gst_event_ref(ev));
        if (r != 0) return r;
    }
    if (!force_video and t.audio != null) {
        r = c.gst_element_send_event(t.audio.?.chain.bin, c.gst_event_ref(ev));
        if (r != 0) return r;
    } else r = 0;
    return r;
}

fn parentElement() *c.GstElementClass {
    return @ptrCast(@alignCast(parent_class.?));
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(e);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_SEEK => return sendToSink(s, ev, false),
        c.GST_EVENT_STEP => {
            var format: c.GstFormat = 0;
            var amount: u64 = 0;
            var rate: f64 = 0;
            var flush: c.gboolean = 0;
            var inter: c.gboolean = 0;
            c.gst_event_parse_step(ev, &format, &amount, &rate, &flush, &inter);
            if (format == c.GST_FORMAT_BUFFERS) return sendToSink(s, ev, true);
            return parentElement().send_event.?(e, ev);
        },
        else => return parentElement().send_event.?(e, ev),
    }
}

fn deactivateAll(t: *State) void {
    if (t.deint) |x| {
        activateChain(&x.chain, false);
        addChain(&x.chain, false);
    }
    if (t.video) |x| {
        activateChain(&x.chain, false);
        addChain(&x.chain, false);
    }
    if (t.audio) |x| {
        activateChain(&x.chain, false);
        addChain(&x.chain, false);
    }
    if (t.visc) |x| {
        activateChain(&x.chain, false);
        addChain(&x.chain, false);
    }
    if (t.text) |x| {
        activateChain(&x.chain, false);
        addChain(&x.chain, false);
    }
}

fn nullState(e: ?*c.GstElement) void {
    if (e) |x| _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
}

fn teardown(t: *State) void {
    if (t.video) |v| if (v.out) |o| {
        _ = c.gst_bin_remove(binOf(v.chain.bin), o);
    };
    if (t.audio) |a| if (a.out) |o| {
        _ = c.gst_bin_remove(binOf(a.chain.bin), o);
    };
    if (t.text) |x| if (x.out) |o| {
        _ = c.gst_bin_remove(binOf(x.chain.bin), o);
    };
    nullState(t.audio_sink);
    nullState(t.video_sink);
    nullState(t.visualisation);
    nullState(t.text_sink);
    if (t.video) |v| if (v.filter) |f| {
        _ = c.gst_bin_remove(binOf(v.chain.bin), f);
    };
    if (t.audio) |a| if (a.filter) |f| {
        _ = c.gst_bin_remove(binOf(a.chain.bin), f);
    };
    nullState(t.audio_filter);
    nullState(t.video_filter);
    freeChain(t.deint);
    t.deint = null;
    freeChain(t.video);
    t.video = null;
    freeChain(t.audio);
    t.audio = null;
    freeChain(t.visc);
    t.visc = null;
    freeChain(t.text);
    t.text = null;
}

fn releaseSsyncPads(s: *Self) void {
    const t = st(s);
    var pads: [6]?*c.GstPad = .{ null, null, null, null, null, null };
    var drop_queue = false;
    lock(s);
    for (&t.in, 0..) |*in, i| {
        if (in.ssink == null) continue;
        pads[i * 2] = in.ssink;
        pads[i * 2 + 1] = in.ssrc;
        in.ssink = null;
        in.ssrc = null;
        if (i == 0) drop_queue = true;
    }
    unlock(s);
    const order = [_]usize{ 4, 5, 0, 1, 2, 3 };
    for (order) |i| {
        const p = pads[i] orelse continue;
        if (i % 2 == 0) c.gst_element_release_request_pad(t.ssync, p);
        c.gst_object_unref(p);
    }
    if (drop_queue) removeSsyncQueue(s);
}

fn changeState(e: [*c]c.GstElement, tr_: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    var ret: c.GstStateChangeReturn = c.GST_STATE_CHANGE_SUCCESS;
    switch (tr_) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            t.need_async_start = true;
            asyncStart(s);
            ret = c.GST_STATE_CHANGE_ASYNC;
            _ = reconfigure(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY, c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (tr_ == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
                lock(s);
                unblockAll(s);
                clearVisBlock(t);
                unlock(s);
            }
            lock(s);
            if (t.audio) |a| {
                disconnectAudio(a);
                dropVolume(a);
                dropOffset(&a.ts_offset);
            }
            if (t.video) |v| dropOffset(&v.ts_offset);
            unlock(s);
            dropOverlayAndBalance(s);
        },
        else => {},
    }
    const bret = parentElement().change_state.?(e, tr_);
    switch (bret) {
        c.GST_STATE_CHANGE_FAILURE => {
            asyncDone(s);
            return c.GST_STATE_CHANGE_FAILURE;
        },
        c.GST_STATE_CHANGE_NO_PREROLL => {
            asyncDone(s);
            ret = bret;
        },
        c.GST_STATE_CHANGE_ASYNC => ret = bret,
        else => {},
    }
    switch (tr_) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => t.need_async_start = true,
        c.GST_STATE_CHANGE_PAUSED_TO_READY, c.GST_STATE_CHANGE_READY_TO_NULL => {
            if (tr_ == c.GST_STATE_CHANGE_PAUSED_TO_READY) releaseSsyncPads(s);
            deactivateAll(t);
            asyncDone(s);
            if (tr_ == c.GST_STATE_CHANGE_READY_TO_NULL) teardown(t);
        },
        else => {},
    }
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_FLAGS => setFlags(s, c.g_value_get_flags(v)),
        PROP_VOLUME => setVolume(s, c.g_value_get_double(v)),
        PROP_MUTE => setMute(s, c.g_value_get_boolean(v) != 0),
        PROP_FONT_DESC => setText(s, &t.font_desc, "font-desc", c.g_value_get_string(v)),
        PROP_SUBTITLE_ENCODING => setText(s, &t.sub_encoding, "subtitle-encoding", c.g_value_get_string(v)),
        PROP_VIS_PLUGIN => setVisPlugin(s, elem_or_null(c.g_value_get_object(v))),
        PROP_AV_OFFSET => {
            lock(s);
            t.av_offset = c.g_value_get_int64(v);
            updateAvOffset(s);
            unlock(s);
        },
        PROP_TEXT_OFFSET => {
            lock(s);
            t.text_offset = c.g_value_get_int64(v);
            updateTextOffset(s);
            unlock(s);
        },
        PROP_VIDEO_FILTER => setFilter(s, .video, elem_or_null(c.g_value_get_object(v))),
        PROP_AUDIO_FILTER => setFilter(s, .audio, elem_or_null(c.g_value_get_object(v))),
        PROP_VIDEO_SINK => setSink(s, .video, elem_or_null(c.g_value_get_object(v))),
        PROP_AUDIO_SINK => setSink(s, .audio, elem_or_null(c.g_value_get_object(v))),
        PROP_TEXT_SINK => setSink(s, .text, elem_or_null(c.g_value_get_object(v))),
        PROP_SEND_EVENT_MODE => t.send_event_mode = c.g_value_get_enum(v),
        PROP_FORCE_ASPECT_RATIO => {
            t.force_aspect = c.g_value_get_boolean(v) != 0;
            lock(s);
            if (t.video) |x| if (x.out != null) setAspect(s, x.out);
            unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 5283),
    }
}

fn elem_or_null(p: c.gpointer) ?*c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_FLAGS => c.g_value_set_flags(v, getFlags(s)),
        PROP_VOLUME => c.g_value_set_double(v, getVolume(s)),
        PROP_MUTE => c.g_value_set_boolean(v, @intFromBool(getMute(s))),
        PROP_FONT_DESC => c.g_value_take_string(v, getText(s, &t.font_desc, "font-desc")),
        PROP_SUBTITLE_ENCODING => c.g_value_take_string(v, getText(s, &t.sub_encoding, "subtitle-encoding")),
        PROP_VIS_PLUGIN => c.g_value_take_object(v, getVisPlugin(s)),
        PROP_SAMPLE => c.g_value_take_boxed(v, lastSample(s)),
        PROP_AV_OFFSET => {
            lock(s);
            c.g_value_set_int64(v, t.av_offset);
            unlock(s);
        },
        PROP_TEXT_OFFSET => {
            lock(s);
            c.g_value_set_int64(v, t.text_offset);
            unlock(s);
        },
        PROP_VIDEO_FILTER => c.g_value_take_object(v, getFilter(s, .video)),
        PROP_AUDIO_FILTER => c.g_value_take_object(v, getFilter(s, .audio)),
        PROP_VIDEO_SINK => c.g_value_take_object(v, getSink(s, .video)),
        PROP_AUDIO_SINK => c.g_value_take_object(v, getSink(s, .audio)),
        PROP_TEXT_SINK => c.g_value_take_object(v, getSink(s, .text)),
        PROP_SEND_EVENT_MODE => c.g_value_set_enum(v, t.send_event_mode),
        PROP_FORCE_ASPECT_RATIO => c.g_value_set_boolean(v, @intFromBool(t.force_aspect)),
        else => cm.warnInvalid(FILE, o, id, spec, 5349),
    }
}

fn currentOverlay(s: *Self) ?*c.GstElement {
    cm.lock(s);
    defer cm.unlock(s);
    return if (st(s).overlay) |o| ref(o) else null;
}

fn ovExpose(ov: ?*c.GstVideoOverlay) callconv(.c) void {
    const o = currentOverlay(me(ov)) orelse return;
    c.gst_video_overlay_expose(overlayOf(o));
    c.gst_object_unref(o);
}

fn ovEvents(ov: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    const s = me(ov);
    const o = currentOverlay(s);
    st(s).events_set = true;
    st(s).events = on != 0;
    if (o) |x| {
        c.gst_video_overlay_handle_events(overlayOf(x), on);
        c.gst_object_unref(x);
    }
}

fn ovRect(ov: ?*c.GstVideoOverlay, x: c.gint, y: c.gint, w: c.gint, h: c.gint) callconv(.c) void {
    const s = me(ov);
    const o = currentOverlay(s);
    st(s).rect_set = true;
    st(s).rect = .{ x, y, w, h };
    if (o) |e| {
        _ = c.gst_video_overlay_set_render_rectangle(overlayOf(e), x, y, w, h);
        c.gst_object_unref(e);
    }
}

fn ovHandle(ov: ?*c.GstVideoOverlay, handle: c.guintptr) callconv(.c) void {
    const s = me(ov);
    const o = currentOverlay(s);
    st(s).handle_set = true;
    st(s).handle = handle;
    if (o) |e| {
        c.gst_video_overlay_set_window_handle(overlayOf(e), handle);
        c.gst_object_unref(e);
    }
}

fn overlayInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(iface));
    i.expose = ovExpose;
    i.handle_events = ovEvents;
    i.set_render_rectangle = ovRect;
    i.set_window_handle = ovHandle;
}

fn navSend(nav: ?*c.GstNavigation, ev: ?*c.GstEvent) callconv(.c) void {
    const s = me(nav);
    lock(s);
    const b = if (st(s).video) |v| (if (v.chain.bin) |x| ref(x) else null) else null;
    unlock(s);
    const bin = b orelse return;
    defer c.gst_object_unref(bin);
    if (c.gst_bin_get_by_interface(binOf(bin), c.gst_navigation_get_type())) |n| {
        c.gst_navigation_send_event_simple(@ptrCast(@alignCast(n)), ev);
        c.gst_object_unref(n);
    } else _ = c.gst_element_send_event(bin, ev);
}

fn navigationInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstNavigationInterface = @ptrCast(@alignCast(iface));
    i.send_event_simple = navSend;
}

fn cbList(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    return st(b).channels;
}

fn cbSet(b: ?*c.GstColorBalance, proxy: ?*c.GstColorBalanceChannel, value: c.gint) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    cm.lock(s);
    const bal = if (t.balance) |x| ref(x) else null;
    cm.unlock(s);
    var i: usize = 0;
    var l = t.channels;
    while (l != null) : ({
        l = l.*.next;
        i += 1;
    }) {
        if (channelOf(l.*.data) != proxy) continue;
        t.values[i] = value;
        if (bal) |x| {
            if (matchChannel(balanceOf(x), proxy.?)) |ch| c.gst_color_balance_set_value(balanceOf(x), ch, scale(value, proxy.?, ch));
            c.gst_object_unref(x);
        }
        c.gst_color_balance_value_changed(balanceOf(s), proxy, value);
        return;
    }
    if (bal) |x| c.gst_object_unref(x);
}

fn cbGet(b: ?*c.GstColorBalance, proxy: ?*c.GstColorBalanceChannel) callconv(.c) c.gint {
    const t = st(b);
    var i: usize = 0;
    var l = t.channels;
    while (l != null) : ({
        l = l.*.next;
        i += 1;
    }) {
        if (channelOf(l.*.data) == proxy) return t.values[i];
    }
    c.g_log(null, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", FILE, @as(c_int, 5580), "gst_play_sink_colorbalance_get_value");
    return 0;
}

fn cbType(b: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    const s = me(b);
    cm.lock(s);
    const bal = if (st(s).balance) |x| ref(x) else null;
    cm.unlock(s);
    const x = bal orelse return c.GST_COLOR_BALANCE_SOFTWARE;
    defer c.gst_object_unref(x);
    return c.gst_color_balance_get_balance_type(balanceOf(x));
}

fn balanceInit(iface: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstColorBalanceInterface = @ptrCast(@alignCast(iface));
    i.list_channels = cbList;
    i.set_value = cbSet;
    i.get_value = cbGet;
    i.get_balance_type = cbType;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const t = st(o);
    inline for (.{ "audio_filter", "video_filter", "audio_sink", "video_sink", "visualisation", "text_sink" }) |f| {
        if (@field(t, f)) |x| {
            _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
            c.gst_object_unref(x);
            @field(t, f) = null;
        }
    }
    freeChain(t.deint);
    t.deint = null;
    freeChain(t.video);
    t.video = null;
    freeChain(t.audio);
    t.audio = null;
    freeChain(t.visc);
    t.visc = null;
    freeChain(t.text);
    t.text = null;
    if (t.tee_sink) |p| c.gst_object_unref(p);
    t.tee_sink = null;
    releaseTee(me(o), &t.tee_vissrc);
    releaseTee(me(o), &t.tee_asrc);
    c.g_free(t.font_desc);
    t.font_desc = null;
    c.g_free(t.sub_encoding);
    t.sub_encoding = null;
    t.ssync = null;
    c.g_list_free_full(t.channels, c.g_object_unref);
    t.channels = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const t = st(o);
    c.g_rec_mutex_clear(&t.lock);
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
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const wo = c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS;
    const el_t = c.gst_element_get_type();
    c.g_object_class_install_property(oc, PROP_FLAGS, c.g_param_spec_flags("flags", "Flags", "Flags to control behaviour", flags.flagsType(), DEFAULT_FLAGS, cm.RW));
    c.g_object_class_install_property(oc, PROP_VOLUME, c.g_param_spec_double("volume", "Volume", "The audio volume, 1.0=100%", 0.0, 10.0, 1.0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MUTE, c.g_param_spec_boolean("mute", "Mute", "Mute the audio channel without changing the volume", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FONT_DESC, c.g_param_spec_string("subtitle-font-desc", "Subtitle font description", "Pango font description of font to be used for subtitle rendering", null, wo));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIS_PLUGIN, c.g_param_spec_object("vis-plugin", "Vis plugin", "the visualization element to use (NULL = default)", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_SAMPLE, c.g_param_spec_boxed("sample", "Sample", "The last sample (NULL = no video available)", c.gst_sample_get_type(), ro));
    c.g_object_class_install_property(oc, PROP_AV_OFFSET, c.g_param_spec_int64("av-offset", "AV Offset", "The synchronisation offset between audio and video in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_OFFSET, c.g_param_spec_int64("text-offset", "Text Offset", "The synchronisation offset between text and video in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_FILTER, c.g_param_spec_object("video-filter", "Video filter", "the video filter(s) to apply, if possible", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_FILTER, c.g_param_spec_object("audio-filter", "Audio filter", "the audio filter(s) to apply, if possible", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_SINK, c.g_param_spec_object("video-sink", "Video Sink", "the video output element to use (NULL = default sink)", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_SINK, c.g_param_spec_object("audio-sink", "Audio Sink", "the audio output element to use (NULL = default sink)", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_SINK, c.g_param_spec_object("text-sink", "Text sink", "the text output element to use (NULL = default subtitleoverlay)", el_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_SEND_EVENT_MODE, c.g_param_spec_enum("send-event-mode", "Send event mode", "How to send events received in send_event function", modeType(), MODE_DEFAULT, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORCE_ASPECT_RATIO, c.g_param_spec_boolean("force-aspect-ratio", "Force Aspect Ratio", "When enabled, scaling will respect original aspect ratio", 1, cm.RW));
    const t = cm.typeOfClass(k);
    _ = c.g_signal_new("reconfigure", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "reconfigure"), null, null, null, c.G_TYPE_BOOLEAN, 0, c.G_TYPE_NONE);
    _ = c.g_signal_new("convert-sample", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @offsetOf(Class, "convert_sample"), null, null, null, c.gst_sample_get_type(), 1, c.gst_caps_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &audio_raw_t);
    c.gst_element_class_add_static_pad_template(ec, &audio_t);
    c.gst_element_class_add_static_pad_template(ec, &video_raw_t);
    c.gst_element_class_add_static_pad_template(ec, &video_t);
    c.gst_element_class_add_static_pad_template(ec, &text_t);
    c.gst_element_class_set_static_metadata(ec, "Player Sink", "Generic/Bin/Sink", "Convenience sink for multiple streams", "Wim Taymans <wim.taymans@gmail.com>");
    ec.change_state = changeState;
    ec.send_event = sendEvent;
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releaseRequestPad;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.reconfigure = reconfigure;
    kc.convert_sample = convertSample;
    _ = c.g_type_class_ref(streamsynchronizer.getType());
    _ = c.g_type_class_ref(c.gst_color_balance_channel_get_type());
    c.gst_type_mark_as_plugin_api(modeType(), 0);
    _ = c._gst_debug_category_new("playsink", 0, "play sink");
}

fn proxyChannel(label: [*c]const u8) c.gpointer {
    const ch = channelOf(c.g_object_new(c.gst_color_balance_channel_get_type(), @as([*c]const u8, null)));
    ch.label = c.g_strdup(label);
    ch.min_value = -1000;
    ch.max_value = 1000;
    return ch;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    t.ssync = elem(c.g_object_new(streamsynchronizer.getType(), @as([*c]const u8, null)));
    _ = c.gst_bin_add(binOf(s), t.ssync);
    c.g_rec_mutex_init(&t.lock);
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_SINK;
    c.gst_bin_set_suppressed_flags(binOf(s), c.GST_ELEMENT_FLAG_SOURCE | c.GST_ELEMENT_FLAG_SINK);
    for ([_][*c]const u8{ "CONTRAST", "BRIGHTNESS", "HUE", "SATURATION" }) |l| t.channels = c.g_list_append(t.channels, proxyChannel(l));
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstPlaySink", Class, Self, classInit, init);
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
