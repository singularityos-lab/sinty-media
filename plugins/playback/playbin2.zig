const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const playsink = @import("playsink.zig");
const subtitleoverlay = @import("subtitleoverlay.zig");
const utils = @import("utils.zig");

const FILE = "../gst/playback/gstplaybin2.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const VOLUME_MAX = 10.0;
const DEFAULT_FLAGS = flags.AUDIO | flags.VIDEO | flags.TEXT | flags.SOFT_VOLUME | flags.DEINTERLACE | flags.SOFT_COLORBALANCE;

const PROP_URI = 1;
const PROP_CURRENT_URI = 2;
const PROP_SUBURI = 3;
const PROP_CURRENT_SUBURI = 4;
const PROP_SOURCE = 5;
const PROP_FLAGS = 6;
const PROP_N_VIDEO = 7;
const PROP_CURRENT_VIDEO = 8;
const PROP_N_AUDIO = 9;
const PROP_CURRENT_AUDIO = 10;
const PROP_N_TEXT = 11;
const PROP_CURRENT_TEXT = 12;
const PROP_SUBTITLE_ENCODING = 13;
const PROP_AUDIO_SINK = 14;
const PROP_VIDEO_SINK = 15;
const PROP_VIS_PLUGIN = 16;
const PROP_TEXT_SINK = 17;
const PROP_VIDEO_STREAM_COMBINER = 18;
const PROP_AUDIO_STREAM_COMBINER = 19;
const PROP_TEXT_STREAM_COMBINER = 20;
const PROP_VOLUME = 21;
const PROP_MUTE = 22;
const PROP_SAMPLE = 23;
const PROP_FONT_DESC = 24;
const PROP_CONNECTION_SPEED = 25;
const PROP_BUFFER_SIZE = 26;
const PROP_BUFFER_DURATION = 27;
const PROP_AV_OFFSET = 28;
const PROP_TEXT_OFFSET = 29;
const PROP_RING_BUFFER_MAX_SIZE = 30;
const PROP_FORCE_ASPECT_RATIO = 31;
const PROP_AUDIO_FILTER = 32;
const PROP_VIDEO_FILTER = 33;
const PROP_MULTIVIEW_MODE = 34;
const PROP_MULTIVIEW_FLAGS = 35;

const SIG_ABOUT_TO_FINISH = 0;
const SIG_CONVERT_SAMPLE = 1;
const SIG_VIDEO_CHANGED = 2;
const SIG_AUDIO_CHANGED = 3;
const SIG_TEXT_CHANGED = 4;
const SIG_VIDEO_TAGS_CHANGED = 5;
const SIG_AUDIO_TAGS_CHANGED = 6;
const SIG_TEXT_TAGS_CHANGED = 7;
const SIG_GET_VIDEO_TAGS = 8;
const SIG_GET_AUDIO_TAGS = 9;
const SIG_GET_TEXT_TAGS = 10;
const SIG_GET_VIDEO_PAD = 11;
const SIG_GET_AUDIO_PAD = 12;
const SIG_GET_TEXT_PAD = 13;
const SIG_SOURCE_SETUP = 14;
const SIG_ELEMENT_SETUP = 15;

const AUDIO = 0;
const VIDEO = 1;
const TEXT = 2;

const KEY_COMBINE = "playbin.combine";
const KEY_SINKPAD = "playbin.sinkpad";
const KEY_PROBE = "playbin.event_probe_id";
const KEY_TAGS = "playbin.notify_tags_handler";

const MEDIA = [3][]const [:0]const u8{
    &.{"audio/"},
    &.{ "video/", "image/" },
    &.{ "text/", "application/x-subtitle", "application/x-ssa", "application/x-ass", "subpicture/x-dvd", "subpicture/", "subtitle/" },
};
const KINDS = [3]playsink.Kind{ .audio, .video, .text };
const CHANGED = [3]usize{ SIG_AUDIO_CHANGED, SIG_VIDEO_CHANGED, SIG_TEXT_CHANGED };
const TAGS_CHANGED = [3]usize{ SIG_AUDIO_TAGS_CHANGED, SIG_VIDEO_TAGS_CHANGED, SIG_TEXT_TAGS_CHANGED };
const CURRENT = [3][*c]const u8{ "current-audio", "current-video", "current-text" };
const FLUSH_DONE = [3][*c]const u8{ "playsink-custom-audio-flush-finish", "playsink-custom-video-flush-finish", "playsink-custom-subtitle-flush-finish" };

var raw_audio = c.GstStaticCaps{ .caps = null, .string = "audio/x-raw(ANY)", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var raw_video = c.GstStaticCaps{ .caps = null, .string = "video/x-raw(ANY)", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };

const Combine = struct {
    index: usize,
    combiner: ?*c.GstElement = null,
    channels: std.ArrayList(*c.GstPad) = .empty,
    srcpad: ?*c.GstPad = null,
    sinkpad: ?*c.GstPad = null,
    block_id: c.gulong = 0,
    has_active_pad: bool = false,
    has_always_ok: bool = false,
    has_tags: bool = false,
};

const Group = struct {
    bin: *Self = undefined,
    lock: c.GMutex = undefined,
    valid: bool = false,
    active: bool = false,
    uri: [*c]u8 = null,
    suburi: [*c]u8 = null,
    sinks: [3]?*c.GstElement = .{ null, null, null },
    udb: ?*c.GstElement = null,
    sub: ?*c.GstElement = null,
    pending: c.gint = 0,
    sub_pending: bool = false,
    have_group_id: bool = false,
    group_id: c.guint = 0,
    ids: [10]c.gulong = std.mem.zeroes([10]c.gulong),
    sub_ids: [5]c.gulong = std.mem.zeroes([5]c.gulong),
    block_id: c.gulong = 0,
    changed_lock: c.GMutex = undefined,
    changed_pending: bool = false,
    flushes_lock: c.GMutex = undefined,
    flushes_init: bool = false,
    flushes: [*c]c.GSList = null,
    pending_buffering: [*c]c.GstMessage = null,
    combine: [3]Combine = .{ .{ .index = 0 }, .{ .index = 1 }, .{ .index = 2 } },
};

const AvElement = struct {
    dec: ?*c.GstElementFactory,
    sink: ?*c.GstElementFactory,
    common: c.guint,
};

const Duration = struct { valid: bool = false, format: c.GstFormat = 0, duration: i64 = 0 };

const State = struct {
    lock: c.GRecMutex = undefined,
    groups: [2]Group = .{ .{}, .{} },
    curr: ?*Group = null,
    next: ?*Group = null,
    speed: u64 = 0,
    current: [3]c.gint = .{ -1, -1, -1 },
    buffer_duration: i64 = -1,
    buffer_size: c.gint = -1,
    mv_mode: c.gint = c.GST_VIDEO_MULTIVIEW_FRAME_PACKING_NONE,
    mv_flags: c.guint = c.GST_VIDEO_MULTIVIEW_FLAGS_NONE,
    sink: ?*playsink.Self = null,
    source: ?*c.GstElement = null,
    dyn_lock: c.GMutex = undefined,
    shutdown: c.gint = 0,
    async_pending: bool = false,
    elements_lock: c.GMutex = undefined,
    cookie: u32 = 0,
    elements: [*c]c.GList = null,
    have_selector: bool = true,
    pending_flush: [3]bool = .{ false, false, false },
    sinks: [3]?*c.GstElement = .{ null, null, null },
    customs: [3]?*c.GstElement = .{ null, null, null },
    aelements: ?std.ArrayList(AvElement) = null,
    velements: ?std.ArrayList(AvElement) = null,
    duration: [5]Duration = .{ .{}, .{}, .{}, .{}, .{} },
    ring_max: u64 = 0,
    contexts: [*c]c.GList = null,
    is_live: bool = false,
};

pub const Self = extern struct {
    parent: c.GstPipeline,
    st: ?*State,
};

const Class = extern struct {
    parent: c.GstPipelineClass,
    about_to_finish: ?*const fn (?*Self) callconv(.c) void,
    video_changed: ?*const fn (?*Self) callconv(.c) void,
    audio_changed: ?*const fn (?*Self) callconv(.c) void,
    text_changed: ?*const fn (?*Self) callconv(.c) void,
    video_tags_changed: ?*const fn (?*Self, c.gint) callconv(.c) void,
    audio_tags_changed: ?*const fn (?*Self, c.gint) callconv(.c) void,
    text_tags_changed: ?*const fn (?*Self, c.gint) callconv(.c) void,
    get_video_tags: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstTagList,
    get_audio_tags: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstTagList,
    get_text_tags: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstTagList,
    convert_sample: ?*const fn (?*Self, [*c]c.GstCaps) callconv(.c) ?*c.GstSample,
    get_video_pad: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstPad,
    get_audio_pad: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstPad,
    get_text_pad: ?*const fn (?*Self, c.gint) callconv(.c) ?*c.GstPad,
};

var signals: [16]c.guint = std.mem.zeroes([16]c.guint);
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

fn classOf(e: anytype) *c.GObjectClass {
    return @ptrCast(@alignCast(gobj(e).g_type_instance.g_class));
}

fn eclass() *c.GstElementClass {
    return @ptrCast(@alignCast(parent_class.?));
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

fn glock(g: *Group) void {
    c.g_mutex_lock(&g.lock);
}

fn gunlock(g: *Group) void {
    c.g_mutex_unlock(&g.lock);
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, s);
}

fn isShutdown(t: *State) bool {
    return c.g_atomic_int_get(&t.shutdown) != 0;
}

fn shutdownLock(s: *Self) bool {
    const t = st(s);
    if (isShutdown(t)) return false;
    c.g_mutex_lock(&t.dyn_lock);
    if (isShutdown(t)) {
        c.g_mutex_unlock(&t.dyn_lock);
        return false;
    }
    return true;
}

fn shutdownUnlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).dyn_lock);
}

fn removeSignal(o: ?*c.GstElement, id: *c.gulong) void {
    if (id.* != 0) {
        c.g_signal_handler_disconnect(o, id.*);
        id.* = 0;
    }
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

fn initGroup(s: *Self, g: *Group) void {
    g.* = .{ .bin = s };
    c.g_mutex_init(&g.lock);
    c.g_mutex_init(&g.changed_lock);
}

fn freeGroup(g: *Group) void {
    c.g_free(g.uri);
    c.g_free(g.suburi);
    for (&g.combine) |*cb| cb.channels.deinit(A);
    c.g_mutex_clear(&g.lock);
    for (&g.sinks) |*x| {
        if (x.*) |y| c.gst_object_unref(y);
        x.* = null;
    }
    g.changed_pending = false;
    c.g_mutex_clear(&g.changed_lock);
    c.g_slist_free(g.flushes);
    g.flushes = null;
    if (g.flushes_init) c.g_mutex_clear(&g.flushes_lock);
    g.flushes_init = false;
    if (g.pending_buffering != null) c.gst_message_unref(g.pending_buffering);
    g.pending_buffering = null;
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

fn isType(f: ?*c.GstElementFactory, t: c.GstElementFactoryListType) bool {
    return c.gst_element_factory_list_is_type(f, t) != 0;
}

fn compareFactories(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const fa: ?*c.GstElementFactory = @ptrCast(@alignCast(@constCast(a)));
    const fb: ?*c.GstElementFactory = @ptrCast(@alignCast(@constCast(b)));
    const sa = isType(fa, c.GST_ELEMENT_FACTORY_TYPE_SINK);
    const sb = isType(fb, c.GST_ELEMENT_FACTORY_TYPE_SINK);
    if (sa and !sb) return -1;
    if (!sa and sb) return 1;
    const pa = isType(fa, c.GST_ELEMENT_FACTORY_TYPE_PARSER);
    const pb = isType(fb, c.GST_ELEMENT_FACTORY_TYPE_PARSER);
    if (pa and !pb) return -1;
    if (!pa and pb) return 1;
    return c.gst_plugin_feature_rank_compare_func(a, b);
}

fn name(f: anytype) []const u8 {
    return std.mem.span(cm.obj(f).name);
}

fn byDecoder(_: void, a: AvElement, b: AvElement) bool {
    return std.mem.order(u8, name(a.dec), name(b.dec)) == .lt;
}

fn rankOf(f: ?*c.GstElementFactory) i64 {
    return c.gst_plugin_feature_get_rank(@ptrCast(f));
}

fn avCompare(a: *const AvElement, b: *const AvElement) c.gint {
    var ra: i64 = 0;
    var rb: i64 = 0;
    const both = a.sink != null and b.sink != null;
    if (both) {
        ra = rankOf(a.dec) * rankOf(a.sink);
        rb = rankOf(b.dec) * rankOf(b.sink);
    } else {
        ra = rankOf(a.dec);
        rb = rankOf(b.dec);
    }
    const diff = rb - ra;
    if (diff < 0) return -1;
    if (diff > 0) return 1;
    const cd: c.gint = @bitCast(b.common -% a.common);
    if (cd != 0) return cd;
    if (both) {
        const d = c.strcmp(cm.obj(a.sink).name, cm.obj(b.sink).name);
        if (d != 0) return d;
    }
    return c.strcmp(cm.obj(a.dec).name, cm.obj(b.dec).name);
}

fn avCompareList(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return avCompare(@ptrCast(@alignCast(a)), @ptrCast(@alignCast(b)));
}

fn freeAv(list: *std.ArrayList(AvElement)) void {
    for (list.items) |x| {
        if (x.dec) |d| c.gst_object_unref(d);
        if (x.sink) |k| c.gst_object_unref(k);
    }
    list.deinit(A);
}

fn createAv(s: *Self, audio: bool) std.ArrayList(AvElement) {
    const sinks = if (audio)
        c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_SINK | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO, c.GST_RANK_MARGINAL)
    else
        c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_SINK | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE, c.GST_RANK_MARGINAL);
    const decs = if (audio)
        c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO, c.GST_RANK_MARGINAL)
    else
        c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE, c.GST_RANK_MARGINAL);
    var out: std.ArrayList(AvElement) = .empty;
    const fl = playsink.getFlags(ps(s));
    var dl = decs;
    while (dl != null) : (dl = dl.*.next) {
        const d: ?*c.GstElementFactory = @ptrCast(@alignCast(dl.*.data));
        var sl = sinks;
        while (sl != null) : (sl = sl.*.next) {
            const k: ?*c.GstElementFactory = @ptrCast(@alignCast(sl.*.data));
            const n = utils.commonCapsFeatures(d, k, fl, audio);
            if (n < 1) continue;
            out.append(A, .{ .dec = @ptrCast(@alignCast(c.gst_object_ref(d))), .sink = @ptrCast(@alignCast(c.gst_object_ref(k))), .common = n }) catch @panic("oom");
        }
    }
    std.mem.sort(AvElement, out.items, {}, byDecoder);
    c.gst_plugin_feature_list_free(decs);
    c.gst_plugin_feature_list_free(sinks);
    return out;
}

fn updateElements(s: *Self) void {
    const t = st(s);
    const cookie = c.gst_registry_get_feature_list_cookie(c.gst_registry_get());
    if (t.elements == null or t.cookie != cookie) {
        if (t.elements != null) c.gst_plugin_feature_list_free(t.elements);
        const a = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DECODABLE, c.GST_RANK_MARGINAL);
        const b = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_AUDIOVIDEO_SINKS, c.GST_RANK_MARGINAL);
        t.elements = c.g_list_sort(c.g_list_concat(a, b), compareFactories);
    }
    if (t.aelements == null or t.cookie != cookie) {
        if (t.aelements) |*x| freeAv(x);
        t.aelements = createAv(s, true);
    }
    if (t.velements == null or t.cookie != cookie) {
        if (t.velements) |*x| freeAv(x);
        t.velements = createAv(s, false);
    }
    t.cookie = cookie;
}

fn decoderRange(list: []AvElement, f: ?*c.GstElementFactory) []AvElement {
    const key = name(f);
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (std.mem.order(u8, name(list[mid].dec), key) == .lt) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < list.len and std.mem.eql(u8, name(list[end].dec), key)) end += 1;
    return list[lo..end];
}

fn createDecoders(factories: [*c]c.GList, avs: []AvElement, fl: c.guint) [*c]c.GList {
    if (!cm.that(factories != null, "create_decoders_list", "factory_list != NULL")) return null;
    var out: [*c]c.GList = null;
    var picks: [*c]c.GList = null;
    var temps: std.ArrayList(*AvElement) = .empty;
    defer {
        for (temps.items) |x| A.destroy(x);
        temps.deinit(A);
    }
    var l = factories;
    while (l != null) : (l = l.*.next) {
        const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        if (isType(f, c.GST_ELEMENT_FACTORY_TYPE_PARSER) or isType(f, c.GST_ELEMENT_FACTORY_TYPE_SINK)) {
            out = c.g_list_prepend(out, c.gst_object_ref(f));
        } else if (!((fl & flags.FORCE_SW_DECODERS) != 0 and isType(f, c.GST_ELEMENT_FACTORY_TYPE_HARDWARE))) {
            const range = decoderRange(avs, f);
            if (range.len == 0) {
                const x = A.create(AvElement) catch @panic("oom");
                x.* = .{ .dec = f, .sink = null, .common = 1 };
                temps.append(A, x) catch @panic("oom");
                picks = c.g_list_prepend(picks, x);
                continue;
            }
            var best: *AvElement = &range[0];
            for (range[1..]) |*x| if (avCompare(x, best) < 0) {
                best = x;
            };
            picks = c.g_list_prepend(picks, best);
        }
    }
    picks = c.g_list_sort(picks, avCompareList);
    l = picks;
    while (l != null) : (l = l.*.next) {
        const x: *AvElement = @ptrCast(@alignCast(l.*.data));
        out = c.g_list_prepend(out, c.gst_object_ref(x.dec));
    }
    c.g_list_free(picks);
    c.gst_plugin_feature_list_free(factories);
    return c.g_list_reverse(out);
}

fn validUri(uri: [*c]const u8) bool {
    if (c.gst_uri_is_valid(uri) == 0) return false;
    for (std.mem.span(uri)) |ch| if (!std.ascii.isPrint(ch) or ch == ' ') return false;
    return true;
}

fn setUri(s: *Self, uri: [*c]const u8) void {
    const t = st(s);
    if (uri != null) _ = validUri(uri);
    lock(s);
    const g = t.next.?;
    glock(g);
    c.g_free(g.uri);
    if (uri != null) {
        g.uri = c.g_strdup(uri);
        g.valid = true;
    } else {
        g.uri = null;
        g.valid = false;
    }
    gunlock(g);
    unlock(s);
}

fn setSuburi(s: *Self, uri: [*c]const u8) void {
    lock(s);
    const g = st(s).next.?;
    glock(g);
    c.g_free(g.suburi);
    g.suburi = c.g_strdup(uri);
    gunlock(g);
    unlock(s);
}

fn setFlags(s: *Self, f: c.guint) void {
    if (f != playsink.getFlags(ps(s))) {
        playsink.setFlags(ps(s), f);
        _ = playsink.requestReconfigure(ps(s));
    }
}

fn currentGroup(t: *State) *Group {
    return t.curr orelse t.next.?;
}

fn channelPad(s: *Self, k: usize, stream: c.gint) ?*c.GstPad {
    lock(s);
    defer unlock(s);
    const g = currentGroup(st(s));
    const ch = g.combine[k].channels.items;
    if (stream < 0 or @as(usize, @intCast(stream)) >= ch.len) return null;
    return @ptrCast(@alignCast(c.gst_object_ref(ch[@intCast(stream)])));
}

fn getVideoPad(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstPad {
    return channelPad(s.?, VIDEO, stream);
}

fn getAudioPad(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstPad {
    return channelPad(s.?, AUDIO, stream);
}

fn getTextPad(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstPad {
    return channelPad(s.?, TEXT, stream);
}

fn tagsOf(s: *Self, k: usize, stream: c.gint) ?*c.GstTagList {
    lock(s);
    defer unlock(s);
    const g = currentGroup(st(s));
    const cb = &g.combine[k];
    if (stream < 0 or @as(usize, @intCast(stream)) >= cb.channels.items.len or !cb.has_tags) return null;
    var res: ?*c.GstTagList = null;
    c.g_object_get(gobj(cb.channels.items[@intCast(stream)]), "tags", &res, N);
    return res;
}

fn getVideoTags(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstTagList {
    return tagsOf(s.?, VIDEO, stream);
}

fn getAudioTags(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstTagList {
    return tagsOf(s.?, AUDIO, stream);
}

fn getTextTags(s: ?*Self, stream: c.gint) callconv(.c) ?*c.GstTagList {
    return tagsOf(s.?, TEXT, stream);
}

fn convertSample(s: ?*Self, caps: [*c]c.GstCaps) callconv(.c) ?*c.GstSample {
    var out: ?*c.GstSample = null;
    c.g_signal_emit_by_name(st(s.?).sink, "convert-sample", caps, &out);
    return out;
}

fn streamNumber(cb: *Combine) c.gint {
    if (!cb.has_active_pad) return -1;
    for (cb.channels.items, 0..) |p, i| {
        const parent: *c.GObject = @ptrCast(@alignCast(c.gst_pad_get_parent(p) orelse continue));
        var cur: ?*c.GstPad = null;
        c.g_object_get(parent, "active-pad", &cur, N);
        c.gst_object_unref(parent);
        if (cur == p) {
            c.gst_object_unref(cur);
            return @intCast(i);
        }
        if (cur) |x| c.gst_object_unref(x);
    }
    return -1;
}

fn sendCustom(combiner: ?*c.GstObject, ev_name: [*c]const u8) bool {
    const src = c.gst_element_get_static_pad(@ptrCast(@alignCast(combiner)), "src");
    defer c.gst_object_unref(src);
    const peer = c.gst_pad_get_peer(src) orelse return false;
    _ = c.gst_pad_send_event(peer, c.gst_event_new_custom(c.GST_EVENT_CUSTOM_DOWNSTREAM_OOB, c.gst_structure_new_empty(ev_name)));
    c.gst_object_unref(peer);
    return true;
}

fn padsOf(e: ?*c.GstElement, comptime f: fn (?*c.GstPad, *Group, bool) void, g: *Group, flag: bool) void {
    const it = c.gst_element_iterate_src_pads(e) orelse return;
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                f(@ptrCast(@alignCast(c.g_value_get_object(&item))), g, flag);
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => c.gst_iterator_resync(it),
            else => return,
        }
    }
}

fn blockSerialized(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (cm.isEvent(info.*.data) and !cm.eventSerialized(info.*.data)) return c.GST_PAD_PROBE_PASS;
    return c.GST_PAD_PROBE_OK;
}

fn blockOne(pad: ?*c.GstPad, g: *Group, block: bool) void {
    if (block) {
        g.block_id = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, blockSerialized, null, null);
    } else if (g.block_id != 0) {
        c.gst_pad_remove_probe(pad, g.block_id);
        g.block_id = 0;
    }
}

fn subBlock(g: *Group, block: bool) void {
    padsOf(g.sub, blockOne, g, block);
}

fn subSeekStart(g: *Group) void {
    const it = c.gst_element_iterate_src_pads(g.sub) orelse return;
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    if (c.gst_iterator_next(it, &item) != c.GST_ITERATOR_OK) return;
    defer c.g_value_unset(&item);
    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&item) orelse return));
    var ev = c.gst_event_new_seek(1.0, c.GST_FORMAT_BYTES, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, -1);
    const seq = c.gst_event_get_seqnum(ev);
    c.g_mutex_lock(&g.flushes_lock);
    g.flushes = c.g_slist_append(g.flushes, @ptrFromInt(seq));
    c.g_mutex_unlock(&g.flushes_lock);
    if (c.gst_pad_send_event(pad, ev) != 0) return;
    ev = c.gst_event_new_seek(1.0, c.GST_FORMAT_TIME, c.GST_SEEK_FLAG_FLUSH, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, -1);
    c.gst_event_set_seqnum(ev, seq);
    if (c.gst_pad_send_event(pad, ev) == 0) {
        c.g_mutex_lock(&g.flushes_lock);
        g.flushes = c.g_slist_remove(g.flushes, @ptrFromInt(seq));
        c.g_mutex_unlock(&g.flushes_lock);
    }
}

fn parentElementOfPeer(p: ?*c.GstPad) ?*c.GstElement {
    const peer = c.gst_pad_get_peer(p) orelse return null;
    defer c.gst_object_unref(peer);
    return c.gst_pad_get_parent_element(peer);
}

fn setCurrent(s: *Self, k: usize, stream: c.gint) bool {
    const t = st(s);
    lock(s);
    const g = currentGroup(t);
    const cb = &g.combine[k];
    if (!cb.has_active_pad) {
        unlock(s);
        return false;
    }
    const pad: ?*c.GstPad = if (stream == -1 or cb.channels.items.len <= @as(usize, @bitCast(@as(isize, stream)))) null else @ptrCast(@alignCast(c.gst_object_ref(cb.channels.items[@intCast(stream)])));
    unlock(s);
    const sinkpad = pad orelse return true;
    defer c.gst_object_unref(sinkpad);
    const comb = c.gst_pad_get_parent(sinkpad) orelse return true;
    var old: ?*c.GstPad = null;
    c.g_object_get(gobj(comb), "active-pad", &old, N);
    if (old != sinkpad) {
        if (k == TEXT) {
            const pe = parentElementOfPeer(sinkpad);
            const ope = if (old) |o| parentElementOfPeer(o) else null;
            const need_block = ope == g.sub and pe != ope;
            const need_unblock = pe == g.sub and pe != ope;
            const need_seek = pe == g.sub;
            if (pe) |x| c.gst_object_unref(x);
            if (ope) |x| c.gst_object_unref(x);
            if (need_block) subBlock(g, true);
            if (sendCustom(comb, "playsink-custom-subtitle-flush")) t.pending_flush[k] = true;
            c.g_object_set(gobj(comb), "active-pad", sinkpad, N);
            if (need_unblock) subBlock(g, false);
            if (need_seek) subSeekStart(g);
        } else {
            const ev_name: [*c]const u8 = if (k == VIDEO) "playsink-custom-video-flush" else "playsink-custom-audio-flush";
            if (sendCustom(comb, ev_name)) t.pending_flush[k] = true;
            c.g_object_set(gobj(comb), "active-pad", sinkpad, N);
        }
    }
    if (old) |o| c.gst_object_unref(o);
    c.gst_object_unref(comb);
    return true;
}

fn removeCombinePads(s: *Self, cb: *Combine) void {
    if (cb.sinkpad) |sp| {
        _ = c.gst_pad_unlink(cb.srcpad, sp);
        playsink.releasePad(ps(s), sp);
        c.gst_object_unref(sp);
        cb.sinkpad = null;
    }
    c.gst_object_unref(cb.srcpad);
    cb.srcpad = null;
}

fn setSink(s: *Self, k: usize, sink: ?*c.GstElement) void {
    const t = st(s);
    playsink.setSink(ps(s), KINDS[k], sink);
    if (t.sinks[k]) |o| c.gst_object_unref(o);
    t.sinks[k] = if (sink) |x| @ptrCast(@alignCast(c.gst_object_ref(x))) else null;
}

fn setCombiner(s: *Self, k: usize, comb: ?*c.GstElement) void {
    const p = &st(s).customs[k];
    lock(s);
    defer unlock(s);
    if (p.* == comb) return;
    const old = p.*;
    if (comb) |x| _ = c.gst_object_ref_sink(x);
    p.* = comb;
    if (old) |o| c.gst_object_unref(o);
}

fn setEncoding(s: *Self, v: [*c]const c.GValue) void {
    const t = st(s);
    lock(s);
    const enc = c.g_value_get_string(v);
    for (&t.groups) |*g| {
        if (g.udb) |e| c.g_object_set(gobj(e), "subtitle-encoding", enc, N);
        if (g.sub) |e| c.g_object_set(gobj(e), "subtitle-encoding", enc, N);
    }
    c.g_object_set_property(gobj(t.sink), "subtitle-encoding", v);
    unlock(s);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => setUri(s, c.g_value_get_string(v)),
        PROP_SUBURI => setSuburi(s, c.g_value_get_string(v)),
        PROP_FLAGS => {
            const f = c.g_value_get_flags(v);
            setFlags(s, f);
            if (t.curr) |g| {
                glock(g);
                if (g.udb) |e| c.g_object_set(gobj(e), "download", @as(c.gboolean, @intFromBool(f & flags.DOWNLOAD != 0)), "force-sw-decoders", @as(c.gboolean, @intFromBool(f & flags.FORCE_SW_DECODERS != 0)), N);
                gunlock(g);
            }
        },
        PROP_CURRENT_VIDEO => _ = setCurrent(s, VIDEO, c.g_value_get_int(v)),
        PROP_CURRENT_AUDIO => _ = setCurrent(s, AUDIO, c.g_value_get_int(v)),
        PROP_CURRENT_TEXT => _ = setCurrent(s, TEXT, c.g_value_get_int(v)),
        PROP_SUBTITLE_ENCODING => setEncoding(s, v),
        PROP_VIDEO_FILTER => playsink.setFilter(ps(s), .video, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_FILTER => playsink.setFilter(ps(s), .audio, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIDEO_SINK => setSink(s, VIDEO, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_SINK => setSink(s, AUDIO, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIS_PLUGIN => playsink.setVisPlugin(ps(s), @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_TEXT_SINK => setSink(s, TEXT, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VIDEO_STREAM_COMBINER => setCombiner(s, VIDEO, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_AUDIO_STREAM_COMBINER => setCombiner(s, AUDIO, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_TEXT_STREAM_COMBINER => setCombiner(s, TEXT, @ptrCast(@alignCast(c.g_value_get_object(v)))),
        PROP_VOLUME => playsink.setVolume(ps(s), c.g_value_get_double(v)),
        PROP_MUTE => playsink.setMute(ps(s), c.g_value_get_boolean(v) != 0),
        PROP_FONT_DESC => c.g_object_set_property(gobj(t.sink), "subtitle-font-desc", v),
        PROP_CONNECTION_SPEED => {
            lock(s);
            t.speed = c.g_value_get_uint64(v) *% 1000;
            const speed = t.speed;
            for ([_]?*Group{ t.curr, t.next }) |gg| if (gg) |g| {
                glock(g);
                if (g.udb) |e| c.g_object_set(gobj(e), "connection-speed", speed / 1000, N);
                gunlock(g);
            };
            unlock(s);
        },
        PROP_BUFFER_SIZE => t.buffer_size = c.g_value_get_int(v),
        PROP_BUFFER_DURATION => t.buffer_duration = c.g_value_get_int64(v),
        PROP_AV_OFFSET => c.g_object_set_property(gobj(t.sink), "av-offset", v),
        PROP_TEXT_OFFSET => c.g_object_set_property(gobj(t.sink), "text-offset", v),
        PROP_RING_BUFFER_MAX_SIZE => {
            t.ring_max = c.g_value_get_uint64(v);
            if (t.curr) |g| {
                glock(g);
                if (g.udb) |e| c.g_object_set(gobj(e), "ring-buffer-max-size", t.ring_max, N);
                gunlock(g);
            }
        },
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
        else => cm.warnInvalid(FILE, o, id, spec, 2531),
    }
}

fn currentSink(s: *Self, k: usize) ?*c.GstElement {
    if (playsink.getSink(ps(s), KINDS[k])) |x| return x;
    lock(s);
    defer unlock(s);
    const x = st(s).sinks[k] orelse return null;
    return @ptrCast(@alignCast(c.gst_object_ref(x)));
}

fn currentCombiner(s: *Self, k: usize) ?*c.GstElement {
    const t = st(s);
    lock(s);
    defer unlock(s);
    const x = t.curr.?.combine[k].combiner orelse t.customs[k] orelse return null;
    return @ptrCast(@alignCast(c.gst_object_ref(x)));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI, PROP_SUBURI, PROP_CURRENT_URI, PROP_CURRENT_SUBURI => {
            lock(s);
            const g = if (id == PROP_URI or id == PROP_SUBURI) t.next.? else currentGroup(t);
            c.g_value_set_string(v, if (id == PROP_URI or id == PROP_CURRENT_URI) g.uri else g.suburi);
            unlock(s);
        },
        PROP_SOURCE => {
            cm.lock(s);
            c.g_value_set_object(v, t.source);
            cm.unlock(s);
        },
        PROP_FLAGS => c.g_value_set_flags(v, playsink.getFlags(ps(s))),
        PROP_N_VIDEO, PROP_N_AUDIO, PROP_N_TEXT => {
            lock(s);
            const k: usize = if (id == PROP_N_VIDEO) VIDEO else if (id == PROP_N_AUDIO) AUDIO else TEXT;
            c.g_value_set_int(v, @intCast(currentGroup(t).combine[k].channels.items.len));
            unlock(s);
        },
        PROP_CURRENT_VIDEO, PROP_CURRENT_AUDIO, PROP_CURRENT_TEXT => {
            lock(s);
            const k: usize = if (id == PROP_CURRENT_VIDEO) VIDEO else if (id == PROP_CURRENT_AUDIO) AUDIO else TEXT;
            c.g_value_set_int(v, t.current[k]);
            unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            lock(s);
            c.g_object_get_property(gobj(t.sink), "subtitle-encoding", v);
            unlock(s);
        },
        PROP_VIDEO_FILTER => c.g_value_take_object(v, playsink.getFilter(ps(s), .video)),
        PROP_AUDIO_FILTER => c.g_value_take_object(v, playsink.getFilter(ps(s), .audio)),
        PROP_VIDEO_SINK => c.g_value_take_object(v, currentSink(s, VIDEO)),
        PROP_AUDIO_SINK => c.g_value_take_object(v, currentSink(s, AUDIO)),
        PROP_VIS_PLUGIN => c.g_value_take_object(v, playsink.getVisPlugin(ps(s))),
        PROP_TEXT_SINK => c.g_value_take_object(v, currentSink(s, TEXT)),
        PROP_VIDEO_STREAM_COMBINER => c.g_value_take_object(v, currentCombiner(s, VIDEO)),
        PROP_AUDIO_STREAM_COMBINER => c.g_value_take_object(v, currentCombiner(s, AUDIO)),
        PROP_TEXT_STREAM_COMBINER => c.g_value_take_object(v, currentCombiner(s, TEXT)),
        PROP_VOLUME => c.g_value_set_double(v, playsink.getVolume(ps(s))),
        PROP_MUTE => c.g_value_set_boolean(v, @intFromBool(playsink.getMute(ps(s)))),
        PROP_SAMPLE => c.gst_value_take_sample(v, playsink.lastSample(ps(s))),
        PROP_FONT_DESC => c.g_object_get_property(gobj(t.sink), "subtitle-font-desc", v),
        PROP_CONNECTION_SPEED => {
            lock(s);
            c.g_value_set_uint64(v, t.speed / 1000);
            unlock(s);
        },
        PROP_BUFFER_SIZE => {
            cm.lock(s);
            c.g_value_set_int(v, t.buffer_size);
            cm.unlock(s);
        },
        PROP_BUFFER_DURATION => {
            cm.lock(s);
            c.g_value_set_int64(v, t.buffer_duration);
            cm.unlock(s);
        },
        PROP_AV_OFFSET => c.g_object_get_property(gobj(t.sink), "av-offset", v),
        PROP_TEXT_OFFSET => c.g_object_get_property(gobj(t.sink), "text-offset", v),
        PROP_RING_BUFFER_MAX_SIZE => c.g_value_set_uint64(v, t.ring_max),
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
        else => cm.warnInvalid(FILE, o, id, spec, 2788),
    }
}

fn cacheDuration(t: *State, valid: bool, q: ?*c.GstQuery) void {
    var fmt: c.GstFormat = 0;
    var d: i64 = 0;
    c.gst_query_parse_duration(q, &fmt, &d);
    for (&t.duration) |*x| {
        if (x.format == 0 or fmt == x.format) {
            x.* = .{ .valid = valid, .format = fmt, .duration = if (valid) d else -1 };
            break;
        }
    }
}

fn refreshDurations(s: *Self) void {
    for ([_]c.GstFormat{ c.GST_FORMAT_TIME, c.GST_FORMAT_BYTES, c.GST_FORMAT_DEFAULT }) |f| {
        const q = c.gst_query_new_duration(f);
        const ret = eclass().query.?(elem(s), q) != 0;
        cacheDuration(st(s), ret, q);
        c.gst_query_unref(q);
    }
}

fn query(e: [*c]c.GstElement, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = me(e);
    const t = st(s);
    lock(s);
    defer unlock(s);
    if (cm.queryType(q) == c.GST_QUERY_DURATION) {
        const g = t.curr.?;
        glock(g);
        if (g.pending != 0 or g.changed_pending) {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_duration(q, &fmt, null);
            var ret = false;
            for (t.duration) |x| {
                if (fmt == x.format) {
                    ret = x.valid;
                    c.gst_query_set_duration(q, fmt, if (ret) x.duration else -1);
                    break;
                }
            }
            if (ret) {
                gunlock(g);
                return 1;
            }
        }
        gunlock(g);
    }
    const ret = eclass().query.?(e, q);
    if (cm.queryType(q) == c.GST_QUERY_DURATION) cacheDuration(t, ret != 0, q);
    return ret;
}

fn dropSubtitles(s: *Self, g: *Group) void {
    const sub = g.sub.?;
    for (&g.sub_ids) |*id| removeSignal(sub, id);
    padsOf(sub, removedFromSub, g, false);
    _ = c.gst_object_ref(sub);
    _ = c.gst_bin_remove(binOf(s), sub);
    _ = c.gst_element_set_locked_state(sub, 0);
    c.gst_object_unref(sub);
    glock(g);
    c.g_free(g.suburi);
    g.suburi = null;
    gunlock(g);
    if (g.sub_pending) {
        g.sub_pending = false;
        noMorePads(null, g);
    }
}

fn removedFromSub(pad: ?*c.GstPad, g: *Group, _: bool) void {
    padRemoved(null, pad, g);
}

fn updateContext(s: *Self, ctx: ?*c.GstContext) void {
    const t = st(s);
    cm.lock(s);
    defer cm.unlock(s);
    const ty = c.gst_context_get_context_type(ctx);
    var l = t.contexts;
    while (l != null) : (l = l.*.next) {
        const old: ?*c.GstContext = @ptrCast(@alignCast(l.*.data));
        if (c.strcmp(ty, c.gst_context_get_context_type(old)) == 0 and (c.gst_context_is_persistent(ctx) != 0 or c.gst_context_is_persistent(old) == 0)) {
            _ = c.gst_mini_object_replace(@ptrCast(&l.*.data), @ptrCast(@alignCast(ctx)));
            return;
        }
    }
    t.contexts = c.g_list_prepend(t.contexts, c.gst_context_ref(ctx));
}

fn findContext(t: *State, msg: [*c]c.GstMessage) bool {
    var ty: [*c]const u8 = null;
    _ = c.gst_message_parse_context_type(msg, &ty);
    var l = t.contexts;
    while (l != null) : (l = l.*.next) {
        const x: ?*c.GstContext = @ptrCast(@alignCast(l.*.data));
        if (c.strcmp(ty, c.gst_context_get_context_type(x)) == 0) {
            c.gst_element_set_context(@ptrCast(@alignCast(msg.*.src)), x);
            return true;
        }
    }
    return false;
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var msg = msg_in;
    var reset = false;
    switch (msg.*.type) {
        c.GST_MESSAGE_ASYNC_START, c.GST_MESSAGE_ASYNC_DONE => {
            const src = msg.*.src;
            if (t.curr) |g| if (src != null and ((g.udb != null and src == cm.obj(g.udb)) or (g.sub != null and src == cm.obj(g.sub)))) {
                c.gst_message_unref(msg);
                msg = null;
            };
        },
        c.GST_MESSAGE_STREAM_START => {
            const g = t.curr.?;
            glock(g);
            g.changed_pending = false;
            const buffering = g.pending_buffering;
            g.pending_buffering = null;
            gunlock(g);
            if (buffering != null) parent_class.?.handle_message.?(b, buffering);
        },
        c.GST_MESSAGE_BUFFERING => {
            const g = t.curr.?;
            glock(g);
            if (g.changed_pending) {
                _ = c.gst_message_replace(&g.pending_buffering, msg);
                c.gst_message_unref(msg);
                msg = null;
            }
            gunlock(g);
        },
        c.GST_MESSAGE_ERROR => {
            const g = t.curr;
            if (g != null and g.?.sub != null) {
                if (c.gst_object_has_as_ancestor(msg.*.src, cm.obj(g.?.sub)) != 0) {
                    var err: [*c]c.GError = null;
                    var dbg: [*c]u8 = null;
                    c.gst_message_parse_error(msg, &err, &dbg);
                    const warn = c.gst_message_new_warning(msg.*.src, err, dbg);
                    c.gst_message_unref(msg);
                    c.g_error_free(err);
                    c.g_free(dbg);
                    msg = warn;
                    dropSubtitles(s, g.?);
                }
            } else {
                var details: ?*const c.GstStructure = null;
                c.gst_message_parse_error_details(msg, &details);
                if (details != null and c.gst_structure_has_field(details, "redirect-location") != 0) {
                    const loc = c.gst_structure_get_string(details, "redirect-location");
                    const uri = if (c.gst_uri_is_valid(loc) != 0) c.g_strdup(loc) else c.gst_uri_join_strings(g.?.uri, loc);
                    if (c.g_strcmp0(uri, g.?.uri) != 0) {
                        lock(s);
                        if (!(t.next != null and t.next.?.valid)) setUri(s, uri);
                        unlock(s);
                        _ = setupNext(s, c.GST_STATE_PAUSED);
                        c.gst_message_unref(msg);
                        msg = null;
                    }
                    c.g_free(uri);
                }
            }
        },
        c.GST_MESSAGE_NEED_CONTEXT => {
            cm.lock(s);
            const found = findContext(t, msg);
            cm.unlock(s);
            if (found) {
                c.gst_message_unref(msg);
                msg = null;
            }
        },
        c.GST_MESSAGE_HAVE_CONTEXT => {
            var ctx: ?*c.GstContext = null;
            c.gst_message_parse_have_context(msg, &ctx);
            updateContext(s, ctx);
            c.gst_context_unref(ctx);
        },
        c.GST_MESSAGE_RESET_TIME => {
            if (t.is_live and elem(s).target_state == c.GST_STATE_PLAYING) reset = true;
        },
        else => {},
    }
    if (msg != null) parent_class.?.handle_message.?(b, msg);
    if (reset) _ = c.gst_element_change_state(elem(s), c.GST_STATE_CHANGE_PAUSED_TO_PLAYING);
}

fn deepAdded(b: [*c]c.GstBin, sub: [*c]c.GstBin, child: [*c]c.GstElement) callconv(.c) void {
    c.g_signal_emit(b, signals[SIG_ELEMENT_SETUP], 0, child);
    parent_class.?.deep_element_added.?(b, sub, child);
}

fn activeChanged(combiner: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    lock(s);
    const g = currentGroup(t);
    var found: ?usize = null;
    for (&g.combine, 0..) |*cb, i| if (@as(?*c.GObject, @ptrCast(@alignCast(cb.combiner))) == combiner) {
        found = i;
    };
    const k = found orelse {
        unlock(s);
        return;
    };
    t.current[k] = streamNumber(&g.combine[k]);
    if (t.pending_flush[k]) {
        t.pending_flush[k] = false;
        unlock(s);
        _ = sendCustom(@ptrCast(@alignCast(combiner)), FLUSH_DONE[k]);
    } else unlock(s);
    c.g_object_notify(gobj(s), CURRENT[k]);
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

fn eventProbe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const g: *Group = @ptrCast(@alignCast(data));
    var ev: [*c]c.GstEvent = @ptrCast(@alignCast(info.*.data));
    const kind = cm.eventType(ev);
    if (cm.padParent(pad) == @as(?*anyopaque, @ptrCast(g.sub)) and (kind == c.GST_EVENT_FLUSH_START or kind == c.GST_EVENT_FLUSH_STOP)) {
        const seq = c.gst_event_get_seqnum(ev);
        if (c.g_slist_find(g.flushes, @ptrFromInt(seq))) |item| {
            if (kind == c.GST_EVENT_FLUSH_STOP) g.flushes = c.g_slist_delete_link(g.flushes, item);
        }
    }
    switch (kind) {
        c.GST_EVENT_STREAM_START => {
            glock(g);
            var gid: c.guint = 0;
            if (c.gst_event_parse_group_id(ev, &gid) != 0) {
                if (g.have_group_id) {
                    if (g.group_id != gid) {
                        ev = c.gst_event_copy(ev);
                        c.gst_event_set_group_id(ev, g.group_id);
                        _ = c.gst_mini_object_replace(@ptrCast(&info.*.data), @ptrCast(ev));
                        c.gst_event_unref(ev);
                    }
                } else {
                    g.group_id = gid;
                    g.have_group_id = true;
                }
            } else {
                if (!g.have_group_id) {
                    g.group_id = c.gst_util_group_id_next();
                    g.have_group_id = true;
                }
                ev = c.gst_event_copy(ev);
                c.gst_event_set_group_id(ev, g.group_id);
                _ = c.gst_mini_object_replace(@ptrCast(&info.*.data), @ptrCast(ev));
                c.gst_event_unref(ev);
            }
            gunlock(g);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            const n = std.mem.span(c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0)));
            if (std.mem.startsWith(u8, n, "video/")) {
                const out = multiviewCaps(g.bin, caps);
                if (out != null) {
                    c.gst_event_unref(ev);
                    info.*.data = c.gst_event_new_caps(out);
                    c.gst_caps_unref(out);
                }
            }
        },
        else => {},
    }
    return c.GST_PAD_PROBE_OK;
}

fn matches(list: []const [:0]const u8, value: [*c]const u8, exact: bool) bool {
    const v = std.mem.span(value);
    for (list) |x| {
        if (exact and std.mem.eql(u8, v, x)) return true;
        if (!exact and std.mem.startsWith(u8, v, x)) return true;
    }
    return false;
}

const TagsData = extern struct {
    bin: ?*Self,
    stream: c.gint,
    kind: c.gint,
};

fn notifyTags(_: ?*c.GObject, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const d: *TagsData = @ptrCast(@alignCast(data));
    c.g_signal_emit(d.bin, signals[TAGS_CHANGED[@intCast(d.kind)]], 0, d.stream);
}

fn padAdded(dec: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    const t = st(s);
    if (!shutdownLock(s)) return;
    var caps = c.gst_pad_get_current_caps(pad);
    if (caps == null) caps = c.gst_pad_query_caps(pad, null);
    defer c.gst_caps_unref(caps);
    if (c.gst_caps_get_size(caps) == 0) return;
    const n = c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0));
    var found: ?usize = null;
    var custom: ?*c.GstElement = null;
    var pass: usize = 0;
    while (found == null and pass < 2) : (pass += 1) {
        for (0..3) |i| {
            if (matches(MEDIA[i], n, pass == 0)) {
                found = i;
                break;
            } else if (i == TEXT) {
                const mc = subtitleoverlay.factoryCaps();
                const hit = mc != null and c.gst_caps_can_intersect(mc, caps) != 0;
                c.gst_caps_unref(mc);
                if (hit) {
                    found = i;
                    break;
                }
            }
        }
        if (found) |i| custom = t.customs[i];
    }
    const k = found orelse {
        shutdownUnlock(s);
        return;
    };
    const cb = &g.combine[k];
    glock(g);
    if (cb.combiner == null and t.have_selector) {
        cb.combiner = custom orelse c.gst_element_factory_make("input-selector", null);
        if (cb.combiner == null) {
            t.have_selector = false;
            _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), "input-selector"));
            cm.elementWarning(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(tr("Missing element '%s' - check your GStreamer installation."), "input-selector"), null, FILE, "pad_added_cb", 3470);
        } else {
            const comb = cb.combiner.?;
            cb.has_active_pad = c.g_object_class_find_property(classOf(comb), "active-pad") != null;
            if (custom == null) {
                if (k == TEXT) {
                    c.g_object_set(gobj(comb), "sync-streams", @as(c.gboolean, 1), "sync-mode", @as(c.gint, 1), "cache-buffers", @as(c.gboolean, 1), N);
                } else c.g_object_set(gobj(comb), "sync-streams", @as(c.gboolean, 1), N);
            }
            if (cb.has_active_pad) _ = c.g_signal_connect_data(comb, "notify::active-pad", @ptrCast(&activeChanged), s, null, 0);
            _ = c.gst_element_set_state(comb, c.GST_STATE_PAUSED);
            _ = c.gst_bin_add(binOf(s), comb);
        }
    }
    shutdownUnlock(s);
    if (cb.srcpad == null) {
        cb.srcpad = if (cb.combiner) |comb| c.gst_element_get_static_pad(comb, "src") else @ptrCast(@alignCast(c.gst_object_ref(pad)));
        cb.block_id = c.gst_pad_add_probe(cb.srcpad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, blockSerialized, null, null);
    }
    var changed = false;
    var sinkpad: ?*c.GstPad = null;
    if (cb.combiner) |comb| {
        sinkpad = c.gst_element_request_pad_simple(comb, "sink_%u") orelse {
            cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_PAD, c.g_strdup("Internal playbin error."), c.g_strdup_printf("Failed to get request pad from combiner %p.", comb), FILE, "pad_added_cb", 3644);
            gunlock(g);
            return;
        };
        const sp = sinkpad.?;
        cb.has_always_ok = c.g_object_class_find_property(classOf(sp), "always-ok") != null;
        cb.has_tags = c.g_object_class_find_property(classOf(sp), "tags") != null;
        c.g_object_set_data(gobj(sp), KEY_COMBINE, cb);
        if (cb.has_tags) {
            const d: *TagsData = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(TagsData))));
            d.* = .{ .bin = s, .stream = @intCast(cb.channels.items.len), .kind = @intCast(k) };
            const h = c.g_signal_connect_data(sp, "notify::tags", @ptrCast(&notifyTags), d, @ptrCast(&c.g_free), 0);
            c.g_object_set_data(gobj(sp), KEY_TAGS, @ptrFromInt(h));
        }
        cb.channels.append(A, sp) catch @panic("oom");
        if (c.gst_pad_link(pad, sp) < 0) {
            gunlock(g);
            return;
        }
        c.g_object_set_data(gobj(pad), KEY_SINKPAD, sp);
        changed = true;
    } else c.g_object_set_data(gobj(pad), KEY_COMBINE, cb);
    gunlock(g);
    const probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, eventProbe, g, null);
    c.g_object_set_data(gobj(pad), KEY_PROBE, @ptrFromInt(probe));
    if (changed) {
        if (cb.has_always_ok) c.g_object_set(gobj(sinkpad), "always-ok", @as(c.gboolean, @intFromBool(dec == g.sub)), N);
        c.g_signal_emit(s, signals[CHANGED[k]], 0);
    }
}

fn padRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    var signal: ?usize = null;
    glock(g);
    const probe = @intFromPtr(c.g_object_get_data(gobj(pad), KEY_PROBE));
    if (probe != 0) {
        c.gst_pad_remove_probe(pad, probe);
        c.g_object_set_data(gobj(pad), KEY_PROBE, null);
    }
    if (c.g_object_get_data(gobj(pad), KEY_COMBINE)) |x| {
        removeCombinePads(s, @ptrCast(@alignCast(x)));
        gunlock(g);
        return;
    }
    const peer: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_get_data(gobj(pad), KEY_SINKPAD) orelse {
        gunlock(g);
        return;
    }));
    _ = c.gst_pad_unlink(pad, peer);
    const comb = elem(c.gst_pad_get_parent(peer));
    if (c.g_object_get_data(gobj(peer), KEY_COMBINE)) |x| {
        const cb: *Combine = @ptrCast(@alignCast(x));
        if (cb.has_tags) {
            const h = @intFromPtr(c.g_object_get_data(gobj(peer), KEY_TAGS));
            if (h != 0) c.g_signal_handler_disconnect(peer, h);
            c.g_object_set_data(gobj(peer), KEY_TAGS, null);
        }
        for (cb.channels.items, 0..) |p, i| if (p == peer) {
            _ = cb.channels.orderedRemove(i);
            break;
        };
        signal = CHANGED[cb.index];
        if (cb.channels.items.len == 0) if (cb.combiner) |cc| {
            removeCombinePads(s, cb);
            _ = c.gst_element_set_state(cc, c.GST_STATE_NULL);
            _ = c.gst_bin_remove(binOf(s), cc);
            cb.combiner = null;
        };
    }
    c.gst_element_release_request_pad(comb, peer);
    c.gst_object_unref(peer);
    c.gst_object_unref(comb);
    gunlock(g);
    if (signal) |x| c.g_signal_emit(s, signals[x], 0);
}

fn noMorePads(dec: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    if (!shutdownLock(s)) {
        glock(g);
        for (&g.combine) |*cb| {
            const sp = cb.srcpad orelse continue;
            if (cb.sinkpad == null) {
                cb.sinkpad = playsink.requestPad(ps(s), .flushing);
                _ = c.gst_object_ref(cb.sinkpad);
                _ = c.gst_pad_link(sp, cb.sinkpad);
            }
            if (cb.block_id != 0) {
                c.gst_pad_remove_probe(sp, cb.block_id);
                cb.block_id = 0;
            }
        }
        gunlock(g);
        return;
    }
    glock(g);
    for (&g.combine) |*cb| {
        if (cb.srcpad != null and cb.sinkpad == null) {
            cb.sinkpad = playsink.requestPad(ps(s), KINDS[cb.index]);
            _ = c.gst_object_ref(cb.sinkpad);
        } else if (cb.srcpad != null and cb.sinkpad != null) {
            playsink.refreshPad(ps(s), cb.sinkpad, KINDS[cb.index]);
        } else if (cb.sinkpad != null and cb.srcpad == null) {
            playsink.releasePad(ps(s), cb.sinkpad);
            c.gst_object_unref(cb.sinkpad);
            cb.sinkpad = null;
        }
        if (cb.sinkpad != null and cb.srcpad != null and c.gst_pad_is_linked(cb.srcpad) == 0) {
            const res = c.gst_pad_link(cb.srcpad, cb.sinkpad);
            if (res != c.GST_PAD_LINK_OK) cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_PAD, c.g_strdup("Internal playbin error."), c.g_strdup_printf("Failed to link combiner to sink. Error %d", res), FILE, "no_more_pads_cb", 3816);
        }
    }
    if (g.pending > 0) g.pending -= 1;
    if (g.sub == dec) g.sub_pending = false;
    const configure = g.pending == 0;
    gunlock(g);
    if (configure) {
        glock(g);
        for (0..3) |k| if (g.sinks[k]) |x| playsink.setSink(ps(s), KINDS[k], x);
        gunlock(g);
        glock(g);
        for (&g.combine) |*cb| if (cb.srcpad) |sp| if (cb.block_id != 0) {
            c.gst_pad_remove_probe(sp, cb.block_id);
            cb.block_id = 0;
        };
        gunlock(g);
        _ = playsink.requestReconfigure(ps(s));
    }
    shutdownUnlock(s);
    if (configure) asyncDone(s);
}

fn drained(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    c.g_signal_emit(g.bin, signals[SIG_ABOUT_TO_FINISH], 0);
    _ = setupNext(g.bin, c.GST_STATE_PAUSED);
}

fn canSink(f: ?*c.GstElementFactory, caps: [*c]c.GstCaps) bool {
    var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
    while (tl) |n| : (tl = n.next) {
        const tp: *c.GstStaticPadTemplate = @ptrCast(@alignCast(n.data));
        if (tp.direction != c.GST_PAD_SINK) continue;
        const tc = c.gst_static_caps_get(&tp.static_caps);
        defer c.gst_caps_unref(tc);
        if (c.gst_caps_is_any(tc) == 0 and c.gst_caps_is_subset(caps, tc) != 0) return true;
    }
    return false;
}

fn appendObject(arr: [*c]c.GValueArray, o: ?*anyopaque) [*c]c.GValueArray {
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.G_TYPE_OBJECT);
    c.g_value_set_object(&v, o);
    const r = c.g_value_array_append(arr, &v);
    c.g_value_unset(&v);
    return r;
}

fn autoplugFactories(_: ?*c.GstElement, _: ?*c.GstPad, caps_in: [*c]c.GstCaps, data: c.gpointer) callconv(.c) [*c]c.GValueArray {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    const t = st(s);
    var caps = caps_in;
    const own = caps == null;
    if (own) caps = c.gst_caps_new_any();
    defer if (own) c.gst_caps_unref(caps);
    c.g_mutex_lock(&t.elements_lock);
    updateElements(s);
    var list = c.gst_element_factory_list_filter(t.elements, caps, c.GST_PAD_SINK, c.gst_caps_is_fixed(caps));
    c.g_mutex_unlock(&t.elements_lock);
    var audio = false;
    var video = false;
    if (c.gst_caps_is_any(caps) == 0) {
        var l = list;
        while (l != null) : (l = l.*.next) {
            const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
            video = isType(f, c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE);
            audio = isType(f, c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO);
            if (audio or video) break;
        }
    }
    if (audio or video) {
        const fl = playsink.getFlags(ps(s));
        c.g_mutex_lock(&t.elements_lock);
        const avs = if (audio) t.aelements.?.items else t.velements.?.items;
        list = createDecoders(list, avs, fl);
        c.g_mutex_unlock(&t.elements_lock);
    }
    var res = c.g_value_array_new(c.g_list_length(list) + 2);
    if (g.sinks[AUDIO]) |x| {
        const f = c.gst_element_get_factory(x);
        if (f != null and canSink(f, caps)) res = appendObject(res, f);
    }
    if (g.sinks[VIDEO]) |x| {
        const f = c.gst_element_get_factory(x);
        if (f != null and canSink(f, caps)) res = appendObject(res, f);
    }
    var l = list;
    while (l != null) : (l = l.*.next) {
        const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
        if (g.sinks[AUDIO] != null and isType(f, c.GST_ELEMENT_FACTORY_TYPE_SINK | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO)) continue;
        if (g.sinks[VIDEO] != null and isType(f, c.GST_ELEMENT_FACTORY_TYPE_SINK | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE)) continue;
        _ = appendObject(res, f);
    }
    c.gst_plugin_feature_list_free(list);
    return res;
}

fn sendEvent(e: [*c]c.GstElement, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) & c.GST_EVENT_TYPE_UPSTREAM != 0) return c.gst_element_send_event(elem(st(e).sink), ev);
    return eclass().send_event.?(e, ev);
}

fn setContext(e: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const s = me(e);
    const t = st(s);
    lock(s);
    for (t.sinks) |x| if (x) |y| c.gst_element_set_context(y, ctx);
    const g = t.curr.?;
    glock(g);
    for (g.sinks) |x| if (x) |y| c.gst_element_set_context(y, ctx);
    gunlock(g);
    unlock(s);
    eclass().set_context.?(e, ctx);
}

fn sinkBus(_: ?*c.GstBus, msg: [*c]c.GstMessage, data: c.gpointer) callconv(.c) c.GstBusSyncReply {
    const s = me(data);
    const t = st(s);
    switch (msg.*.type) {
        c.GST_MESSAGE_ERROR => {
            var forward = false;
            for ([_]usize{ AUDIO, VIDEO, TEXT }) |k| if (t.sinks[k]) |x| if (!forward and c.gst_object_has_as_ancestor(msg.*.src, cm.obj(x)) != 0) {
                forward = true;
            };
            if (forward) _ = c.gst_element_post_message(elem(s), msg) else c.gst_message_unref(msg);
        },
        c.GST_MESSAGE_NEED_CONTEXT => {
            cm.lock(s);
            const found = findContext(t, msg);
            cm.unlock(s);
            if (found) c.gst_message_unref(msg) else _ = c.gst_element_post_message(elem(s), msg);
        },
        c.GST_MESSAGE_HAVE_CONTEXT => {
            var ctx: ?*c.GstContext = null;
            c.gst_message_parse_have_context(msg, &ctx);
            updateContext(s, ctx);
            c.gst_context_unref(ctx);
            _ = c.gst_element_post_message(elem(s), msg);
        },
        else => _ = c.gst_element_post_message(elem(s), msg),
    }
    return c.GST_BUS_DROP;
}

fn activateSink(s: *Self, sink: *c.GstElement, activated: ?*bool) bool {
    if (activated) |a| a.* = false;
    cm.lock(sink);
    const state = sink.current_state;
    cm.unlock(sink);
    if (state >= c.GST_STATE_READY) return true;
    var bus: ?*c.GstBus = null;
    if (cm.obj(sink).parent == null) {
        bus = c.gst_bus_new();
        c.gst_bus_set_sync_handler(bus, sinkBus, s, null);
        c.gst_element_set_bus(sink, bus);
    }
    defer if (bus) |b| {
        c.gst_element_set_bus(sink, null);
        c.gst_object_unref(b);
    };
    if (c.gst_element_set_state(sink, c.GST_STATE_READY) == c.GST_STATE_CHANGE_FAILURE) return false;
    if (activated) |a| a.* = true;
    return true;
}

fn sinkWants(s: *Self, sink: *c.GstElement, caps: [*c]c.GstCaps, ret: *bool) void {
    var act = false;
    if (!activateSink(s, sink, &act)) return;
    if (c.gst_element_get_static_pad(sink, "sink")) |sp| {
        const sc = c.gst_pad_query_caps(sp, null);
        if (c.gst_caps_is_any(sc) == 0) ret.* = c.gst_caps_is_subset(caps, sc) == 0;
        c.gst_caps_unref(sc);
        c.gst_object_unref(sp);
    }
    if (act) _ = c.gst_element_set_state(sink, c.GST_STATE_NULL);
}

fn autoplugContinue(e: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) c.gboolean {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    var ret = true;
    glock(g);
    defer gunlock(g);
    var act = false;
    if (g.sinks[TEXT] != null and activateSink(s, g.sinks[TEXT].?, &act)) {
        if (c.gst_element_get_static_pad(g.sinks[TEXT], "sink")) |sp| {
            const sc = c.gst_pad_query_caps(sp, null);
            if (c.gst_caps_is_any(sc) == 0) ret = c.gst_caps_is_subset(caps, sc) == 0;
            c.gst_caps_unref(sc);
            c.gst_object_unref(sp);
        }
        if (act) _ = c.gst_element_set_state(g.sinks[TEXT], c.GST_STATE_NULL);
    } else {
        const sub = subtitleoverlay.factoryCaps();
        ret = c.gst_caps_is_subset(caps, sub) == 0;
        c.gst_caps_unref(sub);
    }
    if (!ret) return 0;
    if (g.sub != null and c.gst_object_has_as_ancestor(cm.obj(e), cm.obj(g.sub)) != 0) return 1;
    if (g.sinks[AUDIO]) |x| sinkWants(s, x, caps, &ret);
    if (!ret) return 0;
    if (g.sinks[VIDEO]) |x| sinkWants(s, x, caps, &ret);
    return @intFromBool(ret);
}

fn sinkAccepts(sink: *c.GstElement, caps: [*c]c.GstCaps) bool {
    const sp = c.gst_element_get_static_pad(sink, "sink") orelse return true;
    defer c.gst_object_unref(sp);
    const sc = c.gst_pad_query_caps(sp, null);
    defer c.gst_caps_unref(sc);
    return c.gst_caps_is_subset(caps, sc) != 0;
}

fn decoderSelect(s: *Self, g: *Group, factory: ?*c.GstElementFactory, audio: bool) c.gint {
    const t = st(s);
    glock(g);
    defer gunlock(g);
    c.g_mutex_lock(&t.elements_lock);
    defer c.g_mutex_unlock(&t.elements_lock);
    const avs = if (audio) t.aelements.?.items else t.velements.?.items;
    const slot = &g.sinks[if (audio) AUDIO else VIDEO];
    var cands: std.ArrayList(?*AvElement) = .empty;
    defer cands.deinit(A);
    const range = decoderRange(avs, factory);
    if (range.len > 0) {
        var i = range.len;
        while (i > 0) {
            i -= 1;
            cands.append(A, &range[i]) catch @panic("oom");
        }
        std.mem.sort(?*AvElement, cands.items, {}, struct {
            fn lt(_: void, a: ?*AvElement, b: ?*AvElement) bool {
                return avCompare(a.?, b.?) < 0;
            }
        }.lt);
    } else cands.append(A, null) catch @panic("oom");
    var created = false;
    for (cands.items) |ave| {
        if (slot.* == null) if (ave) |x| if (x.sink) |sf| {
            slot.* = c.gst_element_factory_create(sf, null) orelse continue;
            _ = c.gst_object_ref_sink(slot.*);
            if (!activateSink(s, slot.*.?, null)) {
                c.gst_object_unref(slot.*);
                slot.* = null;
                continue;
            }
            created = true;
        };
        const sink = slot.* orelse continue;
        var compatible = false;
        if (c.gst_element_get_static_pad(sink, "sink")) |sp| {
            const fl = playsink.getFlags(ps(s));
            const raw = c.gst_static_caps_get(if (audio) &raw_audio else &raw_video);
            const caps = c.gst_pad_query_caps(sp, null);
            const native = if (audio) fl & flags.NATIVE_AUDIO != 0 else fl & flags.NATIVE_VIDEO != 0;
            if (!native and c.gst_caps_can_intersect(caps, raw) != 0) {
                compatible = c.gst_element_factory_can_src_any_caps(factory, raw) != 0 or c.gst_element_factory_can_src_any_caps(factory, caps) != 0;
            } else compatible = c.gst_element_factory_can_src_any_caps(factory, caps) != 0;
            c.gst_object_unref(sp);
            c.gst_caps_unref(raw);
            c.gst_caps_unref(caps);
        }
        if (compatible) break;
        if (created) {
            _ = c.gst_element_set_state(sink, c.GST_STATE_NULL);
            c.gst_object_unref(sink);
            slot.* = null;
            created = false;
        } else return flags.SELECT_SKIP;
    }
    return flags.SELECT_TRY;
}

fn autoplugSelect(_: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps, factory: ?*c.GstElementFactory, data: c.gpointer) callconv(.c) c.gint {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    if (!isType(factory, c.GST_ELEMENT_FACTORY_TYPE_SINK)) {
        const video = isType(factory, c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE);
        const audio = isType(factory, c.GST_ELEMENT_FACTORY_TYPE_DECODER | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO);
        if (!video and !audio) return flags.SELECT_TRY;
        return decoderSelect(s, g, factory, audio);
    }
    const klass = c.gst_element_factory_get_metadata(factory, c.GST_ELEMENT_METADATA_KLASS);
    var k: usize = 0;
    if (c.strstr(klass, "Audio") != null) {
        k = AUDIO;
    } else if (c.strstr(klass, "Video") != null) {
        k = VIDEO;
    } else return flags.SELECT_SKIP;
    if (playsink.getFlags(ps(s)) & flags.VIS != 0 and k == AUDIO) return flags.SELECT_SKIP;
    glock(g);
    defer gunlock(g);
    const slot = &g.sinks[k];
    if (slot.*) |x| if (x.current_state >= c.GST_STATE_READY) {
        const sink: *c.GstElement = @ptrCast(@alignCast(c.gst_object_ref(x)));
        defer c.gst_object_unref(sink);
        return if (sinkAccepts(sink, caps)) flags.SELECT_EXPOSE else flags.SELECT_SKIP;
    };
    slot.* = c.gst_element_factory_create(factory, null) orelse return flags.SELECT_SKIP;
    _ = c.gst_object_ref_sink(slot.*);
    const el = slot.*.?;
    if (!activateSink(s, el, null)) {
        slot.* = null;
        c.gst_object_unref(el);
        return flags.SELECT_SKIP;
    }
    if (!sinkAccepts(el, caps)) {
        slot.* = null;
        _ = c.gst_element_set_state(el, c.GST_STATE_NULL);
        c.gst_object_unref(el);
        return flags.SELECT_SKIP;
    }
    return flags.SELECT_EXPOSE;
}

fn filterCaps(filter: [*c]c.GstCaps, caps: [*c]c.GstCaps) [*c]c.GstCaps {
    if (filter == null) return caps;
    const i = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(caps);
    return i;
}

fn sinkCaps(sink: ?*c.GstElement, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const sp = c.gst_element_get_static_pad(sink, "sink") orelse return null;
    defer c.gst_object_unref(sp);
    const sc = c.gst_pad_query_caps(sp, filter);
    if (c.gst_caps_is_any(sc) == 0) return sc;
    c.gst_caps_unref(sc);
    return null;
}

fn inSub(g: *Group, pad: ?*c.GstPad) bool {
    return g.sub != null and c.gst_object_has_as_ancestor(cm.obj(pad), cm.obj(g.sub)) != 0;
}

fn queryCaps(udb: ?*c.GstElement, pad: ?*c.GstPad, el: ?*c.GstElement, q: ?*c.GstQuery, g: *Group) bool {
    const s = g.bin;
    var filter: [*c]c.GstCaps = null;
    var result: [*c]c.GstCaps = null;
    glock(g);
    body: {
        c.gst_query_parse_caps(q, &filter);
        const factory = c.gst_element_get_factory(el) orelse break :body;
        var ftype: c.GstElementFactoryListType = 0;
        var have_sink = false;
        if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE)) {
            ftype = c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE;
            if (inSub(g, pad)) break :body;
            if (g.sinks[VIDEO]) |x| {
                result = sinkCaps(x, filter);
                have_sink = true;
            }
        } else if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO)) {
            ftype = c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO;
            if (inSub(g, pad)) break :body;
            if (g.sinks[AUDIO]) |x| {
                result = sinkCaps(x, filter);
                have_sink = true;
            }
        } else if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_SUBTITLE)) {
            ftype = c.GST_ELEMENT_FACTORY_TYPE_MEDIA_SUBTITLE;
            if (st(s).sinks[TEXT]) |x| {
                result = sinkCaps(x, filter);
                have_sink = true;
            } else result = filterCaps(filter, subtitleoverlay.factoryCaps());
        } else break :body;
        if (!have_sink) {
            const fs = autoplugFactories(udb, pad, null, g);
            var i: c.guint = 0;
            while (i < fs.*.n_values) : (i += 1) {
                const f: ?*c.GstElementFactory = @ptrCast(@alignCast(c.g_value_get_object(c.g_value_array_get_nth(fs, i))));
                if (!isType(f, ftype)) continue;
                var tl: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
                while (tl) |n| : (tl = n.next) {
                    var tc = c.gst_static_pad_template_get_caps(@ptrCast(@alignCast(n.data)));
                    if (c.gst_caps_is_any(tc) == 0) {
                        tc = filterCaps(filter, tc);
                        result = if (result == null) tc else c.gst_caps_merge(result, tc);
                    } else c.gst_caps_unref(tc);
                }
            }
            c.g_value_array_free(fs);
        }
    }
    gunlock(g);
    if (result == null) return false;
    if (c.gst_ghost_pad_get_target(@ptrCast(@alignCast(pad)))) |target| {
        var tcaps = filterCaps(filter, c.gst_pad_get_pad_template_caps(target));
        if (c.gst_caps_is_any(tcaps) == 0) {
            const tmp = c.gst_caps_new_empty();
            const n = c.gst_caps_get_size(tcaps);
            var i: c.guint = 0;
            while (i < n) : (i += 1) {
                const feat = c.gst_caps_get_features(tcaps, i);
                const x = c.gst_caps_get_structure(tcaps, i);
                if (c.gst_structure_has_name(x, "video/x-raw") == 0 and c.gst_structure_has_name(x, "audio/x-raw") == 0) {
                    c.gst_caps_append_structure_full(tmp, c.gst_structure_copy(x), c.gst_caps_features_copy(feat));
                } else if (c.gst_caps_features_is_any(feat) != 0 or c.gst_caps_features_is_equal(feat, c.GST_CAPS_FEATURES_MEMORY_SYSTEM_MEMORY()) != 0) {
                    c.gst_caps_append_structure(tmp, c.gst_structure_copy(x));
                }
            }
            c.gst_caps_unref(tcaps);
            tcaps = null;
            result = c.gst_caps_merge(result, tmp);
        } else if (tcaps != null) c.gst_caps_unref(tcaps);
        c.gst_object_unref(target);
    }
    c.gst_query_set_caps_result(q, result);
    c.gst_caps_unref(result);
    return true;
}

fn queryOnSink(sink: ?*c.GstElement, q: ?*c.GstQuery) bool {
    const x = sink orelse return false;
    const sp = c.gst_element_get_static_pad(x, "sink") orelse return false;
    defer c.gst_object_unref(sp);
    return c.gst_pad_query(sp, q) != 0;
}

fn queryContext(pad: ?*c.GstPad, el: ?*c.GstElement, q: ?*c.GstQuery, g: *Group) bool {
    glock(g);
    defer gunlock(g);
    const factory = c.gst_element_get_factory(el) orelse return false;
    if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_VIDEO | c.GST_ELEMENT_FACTORY_TYPE_MEDIA_IMAGE)) {
        if (inSub(g, pad)) return false;
        return queryOnSink(g.sinks[VIDEO], q);
    }
    if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_AUDIO)) {
        if (inSub(g, pad)) return false;
        return queryOnSink(g.sinks[AUDIO], q);
    }
    if (isType(factory, c.GST_ELEMENT_FACTORY_TYPE_MEDIA_SUBTITLE)) return queryOnSink(st(g.bin).sinks[TEXT], q);
    return false;
}

fn autoplugQuery(udb: ?*c.GstElement, pad: ?*c.GstPad, el: ?*c.GstElement, q: ?*c.GstQuery, data: c.gpointer) callconv(.c) c.gboolean {
    const g: *Group = @ptrCast(@alignCast(data));
    return @intFromBool(switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS => queryCaps(udb, pad, el, q, g),
        c.GST_QUERY_CONTEXT => queryContext(pad, el, q, g),
        else => false,
    });
}

fn notifySource(_: ?*c.GstElement, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    const s = g.bin;
    const t = st(s);
    var src: ?*c.GstElement = null;
    c.g_object_get(gobj(g.udb), "source", &src, N);
    cm.lock(s);
    if (t.source) |x| c.gst_object_unref(x);
    t.source = src;
    cm.unlock(s);
    c.g_object_notify(gobj(s), "source");
}

fn sourceSetup(_: ?*c.GstElement, src: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const g: *Group = @ptrCast(@alignCast(data));
    c.g_signal_emit(g.bin, signals[SIG_SOURCE_SETUP], 0, src);
}

fn lockedState(g: *Group, locked: bool) void {
    if (g.udb) |x| _ = c.gst_element_set_locked_state(x, @intFromBool(locked));
    if (g.sub) |x| _ = c.gst_element_set_locked_state(x, @intFromBool(locked));
}

fn connect(o: ?*c.GstElement, signal: [*c]const u8, f: anytype, g: *Group) c.gulong {
    return c.g_signal_connect_data(o, signal, @ptrCast(f), g, null, 0);
}

fn groupSink(s: *Self, g: *Group, k: usize, activated: *bool) bool {
    const t = st(s);
    g.sinks[k] = if (t.sinks[k]) |x| @ptrCast(@alignCast(c.gst_object_ref(x))) else playsink.getSink(ps(s), KINDS[k]);
    const x = g.sinks[k] orelse return true;
    if (activateSink(s, x, activated)) return true;
    if (x == t.sinks[k]) return false;
    c.gst_object_unref(x);
    g.sinks[k] = null;
    return true;
}

fn activateGroup(s: *Self, g: *Group, target: c.GstState) c.GstStateChangeReturn {
    const t = st(s);
    if (!cm.that(g.valid, "activate_group", "group->valid")) return c.GST_STATE_CHANGE_FAILURE;
    if (!cm.that(!g.active, "activate_group", "!group->active")) return c.GST_STATE_CHANGE_FAILURE;
    glock(g);
    var activated: [3]bool = .{ false, false, false };
    var udb: ?*c.GstElement = null;
    fail: {
        for ([_]usize{ AUDIO, VIDEO, TEXT }) |k| if (!groupSink(s, g, k, &activated[k])) break :fail;
        c.g_slist_free(g.flushes);
        g.flushes = null;
        if (!g.flushes_init) {
            c.g_mutex_init(&g.flushes_lock);
            g.flushes_init = true;
        }
        if (g.udb) |x| {
            udb = x;
            _ = c.gst_element_set_state(x, c.GST_STATE_READY);
            _ = c.gst_bin_add(binOf(s), x);
        } else {
            udb = c.gst_element_factory_make("uridecodebin", null) orelse {
                gunlock(g);
                missingDecodebin(s);
                glock(g);
                break :fail;
            };
            _ = c.gst_bin_add(binOf(s), udb);
            g.udb = @ptrCast(@alignCast(c.gst_object_ref(udb)));
        }
        const fl = playsink.getFlags(ps(s));
        c.g_object_set(gobj(udb), "connection-speed", t.speed / 1000, "uri", g.uri, "download", @as(c.gboolean, @intFromBool(fl & flags.DOWNLOAD != 0)), "use-buffering", @as(c.gboolean, @intFromBool(fl & flags.BUFFERING != 0)), "force-sw-decoders", @as(c.gboolean, @intFromBool(fl & flags.FORCE_SW_DECODERS != 0)), "buffer-duration", t.buffer_duration, "buffer-size", t.buffer_size, "ring-buffer-max-size", t.ring_max, N);
        g.ids[0] = connect(udb, "pad-added", &padAdded, g);
        g.ids[1] = connect(udb, "pad-removed", &padRemoved, g);
        g.ids[2] = connect(udb, "no-more-pads", &noMorePads, g);
        g.ids[3] = connect(udb, "notify::source", &notifySource, g);
        g.ids[4] = connect(udb, "source-setup", &sourceSetup, g);
        g.pending = 1;
        g.ids[5] = connect(udb, "drained", &drained, g);
        g.ids[6] = connect(udb, "autoplug-factories", &autoplugFactories, g);
        g.ids[7] = connect(udb, "autoplug-select", &autoplugSelect, g);
        g.ids[8] = connect(udb, "autoplug-continue", &autoplugContinue, g);
        g.ids[9] = connect(udb, "autoplug-query", &autoplugQuery, g);
        var sub: ?*c.GstElement = null;
        if (g.suburi != null) {
            if (g.sub) |x| {
                sub = x;
                _ = c.gst_element_set_state(x, c.GST_STATE_READY);
                _ = c.gst_bin_add(binOf(s), x);
            } else {
                sub = c.gst_element_factory_make("uridecodebin", null) orelse {
                    gunlock(g);
                    missingDecodebin(s);
                    glock(g);
                    break :fail;
                };
                _ = c.gst_bin_add(binOf(s), sub);
                g.sub = @ptrCast(@alignCast(c.gst_object_ref(sub)));
            }
            c.g_object_set(gobj(sub), "connection-speed", t.speed, "uri", g.suburi, N);
            g.sub_ids[0] = connect(sub, "pad-added", &padAdded, g);
            g.sub_ids[1] = connect(sub, "pad-removed", &padRemoved, g);
            g.sub_ids[2] = connect(sub, "no-more-pads", &noMorePads, g);
            g.sub_ids[3] = connect(sub, "autoplug-continue", &autoplugContinue, g);
            g.sub_ids[4] = connect(sub, "autoplug-query", &autoplugQuery, g);
            g.pending = 2;
            g.sub_pending = true;
        } else g.sub_pending = false;
        gunlock(g);
        if (sub) |x| if (c.gst_element_set_state(x, target) == c.GST_STATE_CHANGE_FAILURE) {
            glock(g);
            for (&g.sub_ids) |*id| removeSignal(g.sub, id);
            if (cm.obj(x).parent == cm.obj(s)) _ = c.gst_bin_remove(binOf(s), x);
            if (g.sub_pending) {
                g.pending -= 1;
                g.sub_pending = false;
            }
            _ = c.gst_element_set_state(x, c.GST_STATE_READY);
            c.g_free(g.suburi);
            g.suburi = null;
            gunlock(g);
        };
        const ret = c.gst_element_set_state(udb, target);
        if (ret == c.GST_STATE_CHANGE_FAILURE) {
            glock(g);
            break :fail;
        }
        glock(g);
        lockedState(g, false);
        g.active = true;
        gunlock(g);
        return ret;
    }
    for (0..3) |k| {
        if (g.sinks[k]) |x| {
            if (activated[k]) _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
            c.gst_object_unref(x);
        }
        g.sinks[k] = null;
    }
    if (udb) |x| {
        for (&g.ids) |*id| removeSignal(g.udb, id);
        _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), x);
    }
    gunlock(g);
    return c.GST_STATE_CHANGE_FAILURE;
}

fn missingDecodebin(s: *Self) void {
    _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), "uridecodebin"));
    cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup(tr("Could not create \"uridecodebin\" element.")), null, FILE, "activate_group", 5524);
}

fn deactivateGroup(s: *Self, g: *Group) bool {
    if (!cm.that(g.active, "deactivate_group", "group->active")) return false;
    if (!cm.that(g.valid, "deactivate_group", "group->valid")) return false;
    glock(g);
    g.active = false;
    for (&g.combine) |*cb| {
        if (cb.srcpad != null) removeCombinePads(s, cb);
        if (cb.combiner) |comb| {
            for (cb.channels.items) |p| {
                c.gst_element_release_request_pad(comb, p);
                c.gst_object_unref(p);
            }
            cb.channels.clearRetainingCapacity();
            _ = c.gst_element_set_state(comb, c.GST_STATE_NULL);
            _ = c.gst_bin_remove(binOf(s), comb);
            cb.combiner = null;
        }
    }
    for (&g.sinks) |*x| {
        if (x.*) |y| {
            if (c.gst_object_has_as_ancestor(cm.obj(y), cm.obj(st(s).sink)) == 0) _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
            c.gst_object_unref(y);
        }
        x.* = null;
    }
    if (g.udb) |x| {
        for (&g.ids) |*id| removeSignal(x, id);
        _ = c.gst_bin_remove(binOf(s), x);
    }
    if (g.sub) |x| {
        for (&g.sub_ids) |*id| removeSignal(x, id);
        if (cm.obj(x).parent == cm.obj(s)) _ = c.gst_bin_remove(binOf(s), x);
    }
    g.have_group_id = false;
    gunlock(g);
    return true;
}

fn setupNext(s: *Self, target: c.GstState) c.GstStateChangeReturn {
    const t = st(s);
    lock(s);
    defer unlock(s);
    const ng = t.next;
    if (ng == null or !ng.?.valid) {
        if (target == c.GST_STATE_READY and ng != null and ng.?.uri == null)
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("No URI set"), null, FILE, "setup_next_source", 5739);
        return c.GST_STATE_CHANGE_FAILURE;
    }
    const g = ng.?;
    const old = t.curr;
    if (old) |o| if (o.valid and o.active) {
        g.changed_pending = true;
        refreshDurations(s);
        _ = deactivateGroup(s, o);
        o.valid = false;
    };
    t.curr = g;
    t.next = old;
    const ret = activateGroup(s, g, target);
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        g.changed_pending = false;
        g.valid = false;
    }
    return ret;
}

fn saveCurrent(s: *Self) void {
    const t = st(s);
    lock(s);
    const cur = t.curr;
    if (cur) |g| if (g.valid and g.active) {
        _ = deactivateGroup(s, g);
    };
    t.curr = t.next;
    t.next = cur;
    unlock(s);
}

fn groupsLocked(s: *Self, locked: bool) void {
    const t = st(s);
    lock(s);
    for ([_]*Group{ t.curr.?, t.next.? }) |g| {
        glock(g);
        lockedState(g, locked);
        gunlock(g);
    }
    unlock(s);
}

fn changeState(e: [*c]c.GstElement, tr_: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    var save = false;
    switch (tr_) {
        c.GST_STATE_CHANGE_NULL_TO_READY => t.duration = .{ .{}, .{}, .{}, .{}, .{} },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            t.duration = .{ .{}, .{}, .{}, .{}, .{} };
            c.g_atomic_int_set(&t.shutdown, 0);
            asyncStart(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY, c.GST_STATE_CHANGE_READY_TO_NULL => {
            const down = tr_ == c.GST_STATE_CHANGE_PAUSED_TO_READY or !isShutdown(t);
            if (tr_ == c.GST_STATE_CHANGE_READY_TO_NULL and down) save = true;
            if (down) {
                c.g_atomic_int_set(&t.shutdown, 1);
                t.duration = .{ .{}, .{}, .{}, .{}, .{} };
                c.g_mutex_lock(&t.dyn_lock);
                c.g_mutex_unlock(&t.dyn_lock);
            }
            if (tr_ == c.GST_STATE_CHANGE_READY_TO_NULL) {
                t.duration = .{ .{}, .{}, .{}, .{}, .{} };
                groupsLocked(s, false);
            }
        },
        else => {},
    }
    var ret = eclass().change_state.?(e, tr_);
    if (ret != c.GST_STATE_CHANGE_FAILURE) {
        switch (tr_) {
            c.GST_STATE_CHANGE_READY_TO_PAUSED => {
                ret = setupNext(s, c.GST_STATE_PAUSED);
                if (ret == c.GST_STATE_CHANGE_SUCCESS) ret = c.GST_STATE_CHANGE_ASYNC;
            },
            c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => asyncDone(s),
            c.GST_STATE_CHANGE_PAUSED_TO_READY => {
                t.is_live = false;
                saveCurrent(s);
            },
            c.GST_STATE_CHANGE_READY_TO_NULL => toNull(s, save),
            else => {},
        }
    }
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        asyncDone(s);
        if (tr_ == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
            const cur = t.curr;
            if (cur) |g| {
                if (g.active and g.valid) _ = deactivateGroup(s, g);
                g.valid = false;
            }
            t.curr = t.next;
            t.next = cur;
        }
        return ret;
    }
    if ((tr_ & 0x7) == c.GST_STATE_PAUSED) t.is_live = ret == c.GST_STATE_CHANGE_NO_PREROLL;
    if (ret == c.GST_STATE_CHANGE_NO_PREROLL) asyncDone(s);
    return ret;
}

fn toNull(s: *Self, save: bool) void {
    const t = st(s);
    if (save) saveCurrent(s);
    for (&t.groups) |*g| {
        if (g.active and g.valid) {
            _ = deactivateGroup(s, g);
            g.valid = false;
        }
        if (g.udb) |x| {
            _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
            c.gst_object_unref(x);
            g.udb = null;
        }
        if (g.sub) |x| {
            _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
            c.gst_object_unref(x);
            g.sub = null;
        }
    }
    for (t.sinks) |x| if (x) |y| {
        _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
    };
    for ([_]usize{ VIDEO, AUDIO, TEXT }) |k| if (t.customs[k]) |y| {
        _ = c.gst_element_set_state(y, c.GST_STATE_NULL);
    };
    groupsLocked(s, true);
    cm.lock(s);
    var l = t.contexts;
    while (l != null) {
        const ctx: ?*c.GstContext = @ptrCast(@alignCast(l.*.data));
        if (c.gst_context_is_persistent(ctx) == 0) {
            c.gst_context_unref(ctx);
            const nx = l.*.next;
            t.contexts = c.g_list_delete_link(t.contexts, l);
            l = nx;
        } else l = l.*.next;
    }
    if (t.source) |x| {
        c.gst_object_unref(x);
        t.source = null;
    }
    cm.unlock(s);
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
    for (&t.groups) |*g| freeGroup(g);
    if (t.source) |x| c.gst_object_unref(x);
    for ([_]usize{ VIDEO, AUDIO, TEXT }) |k| if (t.sinks[k]) |x| {
        _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
        c.gst_object_unref(x);
    };
    for ([_]usize{ VIDEO, AUDIO, TEXT }) |k| if (t.customs[k]) |x| {
        _ = c.gst_element_set_state(x, c.GST_STATE_NULL);
        c.gst_object_unref(x);
    };
    if (t.elements != null) c.gst_plugin_feature_list_free(t.elements);
    if (t.aelements) |*x| freeAv(x);
    if (t.velements) |*x| freeAv(x);
    c.g_list_free_full(t.contexts, @ptrCast(&c.gst_mini_object_unref));
    c.g_rec_mutex_clear(&t.lock);
    c.g_mutex_clear(&t.dyn_lock);
    c.g_mutex_clear(&t.elements_lock);
    A.destroy(t);
    me(o).st = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn sig(n: [*c]const u8, t: c.GType, flg: c.GSignalFlags, comptime field: ?[]const u8, ret: c.GType, arg: ?c.GType) c.guint {
    const off: c.guint = if (field) |f| @offsetOf(Class, f) else 0;
    if (arg) |a| return c.g_signal_new(n, t, flg, off, null, null, null, ret, @as(c.guint, 1), a);
    return c.g_signal_new(n, t, flg, off, null, null, null, ret, @as(c.guint, 0), @as(c.GType, c.G_TYPE_NONE));
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
    c.g_object_class_install_property(oc, PROP_SOURCE, c.g_param_spec_object("source", "Source", "Source element", el, ro));
    c.g_object_class_install_property(oc, PROP_FLAGS, c.g_param_spec_flags("flags", "Flags", "Flags to control behaviour", flags.flagsType(), DEFAULT_FLAGS, cm.RW));
    c.g_object_class_install_property(oc, PROP_N_VIDEO, c.g_param_spec_int("n-video", "Number Video", "Total number of video streams", 0, std.math.maxInt(c.gint), 0, ro));
    c.g_object_class_install_property(oc, PROP_CURRENT_VIDEO, c.g_param_spec_int("current-video", "Current Video", "Currently playing video stream (-1 = auto)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_N_AUDIO, c.g_param_spec_int("n-audio", "Number Audio", "Total number of audio streams", 0, std.math.maxInt(c.gint), 0, ro));
    c.g_object_class_install_property(oc, PROP_CURRENT_AUDIO, c.g_param_spec_int("current-audio", "Current audio", "Currently playing audio stream (-1 = auto)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_N_TEXT, c.g_param_spec_int("n-text", "Number Text", "Total number of text streams", 0, std.math.maxInt(c.gint), 0, ro));
    c.g_object_class_install_property(oc, PROP_CURRENT_TEXT, c.g_param_spec_int("current-text", "Current Text", "Currently playing text stream (-1 = auto)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_FILTER, c.g_param_spec_object("video-filter", "Video filter", "the video filter(s) to apply, if possible", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_FILTER, c.g_param_spec_object("audio-filter", "Audio filter", "the audio filter(s) to apply, if possible", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_SINK, c.g_param_spec_object("video-sink", "Video Sink", "the video output element to use (NULL = default sink)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_SINK, c.g_param_spec_object("audio-sink", "Audio Sink", "the audio output element to use (NULL = default sink)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIS_PLUGIN, c.g_param_spec_object("vis-plugin", "Vis plugin", "the visualization element to use (NULL = default)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_SINK, c.g_param_spec_object("text-sink", "Text plugin", "the text output element to use (NULL = default subtitleoverlay)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEO_STREAM_COMBINER, c.g_param_spec_object("video-stream-combiner", "Video stream combiner", "Current video stream combiner (NULL = input-selector)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_AUDIO_STREAM_COMBINER, c.g_param_spec_object("audio-stream-combiner", "Audio stream combiner", "Current audio stream combiner (NULL = input-selector)", el, cm.RW));
    c.g_object_class_install_property(oc, PROP_TEXT_STREAM_COMBINER, c.g_param_spec_object("text-stream-combiner", "Text stream combiner", "Current text stream combiner (NULL = input-selector)", el, cm.RW));
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
    const t = cm.typeOfClass(k);
    const last = c.G_SIGNAL_RUN_LAST;
    const action = c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION;
    const int_t: c.GType = c.G_TYPE_INT;
    const none: c.GType = c.G_TYPE_NONE;
    signals[SIG_ABOUT_TO_FINISH] = sig("about-to-finish", t, last, "about_to_finish", none, null);
    signals[SIG_VIDEO_CHANGED] = sig("video-changed", t, last, "video_changed", none, null);
    signals[SIG_AUDIO_CHANGED] = sig("audio-changed", t, last, "audio_changed", none, null);
    signals[SIG_TEXT_CHANGED] = sig("text-changed", t, last, "text_changed", none, null);
    signals[SIG_VIDEO_TAGS_CHANGED] = sig("video-tags-changed", t, last, "video_tags_changed", none, int_t);
    signals[SIG_AUDIO_TAGS_CHANGED] = sig("audio-tags-changed", t, last, "audio_tags_changed", none, int_t);
    signals[SIG_TEXT_TAGS_CHANGED] = sig("text-tags-changed", t, last, "text_tags_changed", none, int_t);
    signals[SIG_SOURCE_SETUP] = sig("source-setup", t, last, null, none, el);
    signals[SIG_ELEMENT_SETUP] = sig("element-setup", t, last, null, none, el);
    signals[SIG_GET_VIDEO_TAGS] = sig("get-video-tags", t, action, "get_video_tags", c.gst_tag_list_get_type(), int_t);
    signals[SIG_GET_AUDIO_TAGS] = sig("get-audio-tags", t, action, "get_audio_tags", c.gst_tag_list_get_type(), int_t);
    signals[SIG_GET_TEXT_TAGS] = sig("get-text-tags", t, action, "get_text_tags", c.gst_tag_list_get_type(), int_t);
    signals[SIG_CONVERT_SAMPLE] = sig("convert-sample", t, action, "convert_sample", c.gst_sample_get_type(), c.gst_caps_get_type());
    signals[SIG_GET_VIDEO_PAD] = sig("get-video-pad", t, action, "get_video_pad", c.gst_pad_get_type(), int_t);
    signals[SIG_GET_AUDIO_PAD] = sig("get-audio-pad", t, action, "get_audio_pad", c.gst_pad_get_type(), int_t);
    signals[SIG_GET_TEXT_PAD] = sig("get-text-pad", t, action, "get_text_pad", c.gst_pad_get_type(), int_t);
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.get_video_tags = getVideoTags;
    kc.get_audio_tags = getAudioTags;
    kc.get_text_tags = getTextTags;
    kc.convert_sample = convertSample;
    kc.get_video_pad = getVideoPad;
    kc.get_audio_pad = getAudioPad;
    kc.get_text_pad = getTextPad;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Player Bin 2", "Generic/Bin/Player", "Autoplug and play media from an uri", "Wim Taymans <wim.taymans@gmail.com>");
    ec.change_state = changeState;
    ec.query = query;
    ec.set_context = setContext;
    ec.send_event = sendEvent;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    bc.deep_element_added = deepAdded;
    c.gst_type_mark_as_plugin_api(flags.flagsType(), 0);
    _ = c._gst_debug_category_new("playbin", 0, "play bin");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    c.g_rec_mutex_init(&t.lock);
    c.g_mutex_init(&t.dyn_lock);
    t.curr = &t.groups[0];
    t.next = &t.groups[1];
    initGroup(s, &t.groups[0]);
    initGroup(s, &t.groups[1]);
    c.g_mutex_init(&t.elements_lock);
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
            const t = cm.register(c.gst_pipeline_get_type(), "GstPlayBin", Class, Self, classInit, init);
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
