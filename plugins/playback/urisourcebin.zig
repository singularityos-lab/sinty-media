const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const utils = @import("utils.zig");

const FILE = "../gst/playback/gsturisourcebin.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;

const PROP_URI = 1;
const PROP_SOURCE = 2;
const PROP_CONNECTION_SPEED = 3;
const PROP_BUFFER_SIZE = 4;
const PROP_BUFFER_DURATION = 5;
const PROP_DOWNLOAD = 6;
const PROP_DOWNLOAD_DIR = 7;
const PROP_USE_BUFFERING = 8;
const PROP_RING_BUFFER_MAX_SIZE = 9;
const PROP_LOW_WATERMARK = 10;
const PROP_HIGH_WATERMARK = 11;
const PROP_STATISTICS = 12;
const PROP_PARSE_STREAMS = 13;

const SIG_DRAINED = 0;
const SIG_ABOUT_TO_FINISH = 1;
const SIG_SOURCE_SETUP = 2;

const DEFAULT_SIZE: c.guint = 10 * 1024 * 1024;
const DEFAULT_DURATION: i64 = 5 * c.GST_SECOND;

const Info = struct {
    bin: *Self,
    src_pad: ?*c.GstPad,
    typefind: ?*c.GstElement = null,
    pre_parse_queue: ?*c.GstElement = null,
    multiqueue: ?*c.GstElement = null,
    demuxer: ?*c.GstElement = null,
    demuxer_handles_buffering: bool = false,
    streams_aware: bool = false,
    is_parsebin: bool = false,
    outputs: [*c]c.GList = null,
    use_downloadbuffer: bool = false,
    use_queue2: bool = false,
    collection: ?*c.GstStreamCollection = null,
};

const Slot = struct {
    info: *Info,
    stream: ?*c.GstStream = null,
    pending_stream: ?*c.GstStream = null,
    origin: ?*c.GstPad = null,
    pending_pad: ?*c.GstPad = null,
    output: ?*c.GstPad = null,
    is_eos: bool = false,
    queue: ?*c.GstElement = null,
    queue_sink: ?*c.GstPad = null,
    bitrate_id: c.gulong = 0,
    demux_probe: c.gulong = 0,
    pending_probe: c.gulong = 0,
};

pub const Self = extern struct {
    parent: c.GstBin,
    lock: c.GMutex,
    uri: [*c]u8,
    speed: u64,
    activated: c.gboolean,
    flushing: c.gint,
    activation: c.GCond,
    is_stream: c.gboolean,
    is_adaptive: c.gboolean,
    buffer_duration: i64,
    buffer_size: c.gint,
    download: c.gboolean,
    download_dir: [*c]u8,
    use_buffering: c.gboolean,
    low: f64,
    high: f64,
    parse_streams: c.gboolean,
    source: ?*c.GstElement,
    infos: [*c]c.GList,
    numpads: c.guint,
    np_id: c.gulong,
    ring_max: u64,
    buffering: [*c]c.GList,
    last_pct: c.gint,
    buffering_lock: c.GMutex,
    post_lock: c.GMutex,
    collection: ?*c.GstStreamCollection,
};

const Class = extern struct {
    parent: c.GstBinClass,
    drained: ?*const fn (?*c.GstElement) callconv(.c) void,
    about_to_finish: ?*const fn (?*c.GstElement) callconv(.c) void,
};

var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var signals: [3]c.guint = .{ 0, 0, 0 };
var once: cm.Once = .{};
var parent_class: ?*c.GstBinClass = null;
var eos_quark_once: usize = 0;

fn eosQuark() c.GQuark {
    if (c.g_once_init_enter(&eos_quark_once) != 0) c.g_once_init_leave(&eos_quark_once, c.g_quark_from_static_string("urisourcebin-custom-eos"));
    return @intCast(eos_quark_once);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
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

fn lock(s: *Self) void {
    c.g_mutex_lock(&s.lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&s.lock);
}

fn bufLock(s: *Self) void {
    c.g_mutex_lock(&s.buffering_lock);
}

fn bufUnlock(s: *Self) void {
    c.g_mutex_unlock(&s.buffering_lock);
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, s);
}

fn bufSize(s: *Self) c.guint {
    return if (s.buffer_size == -1) DEFAULT_SIZE else @intCast(s.buffer_size);
}

fn bufDuration(s: *Self) i64 {
    return if (s.buffer_duration == -1) DEFAULT_DURATION else s.buffer_duration;
}

fn hasProp(o: anytype, name: [*c]const u8) ?*c.GParamSpec {
    return c.g_object_class_find_property(@ptrCast(@alignCast(gobj(o).g_type_instance.g_class)), name);
}

fn coreError(s: *Self, code: c.gint, text: [*c]u8, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_core_error_quark(), code, text, dbg, FILE, func, line);
}

fn missingPlugin(s: *Self, name: [*c]const u8) void {
    _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), name));
    coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(tr("Missing element '%s' - check your GStreamer installation."), name), null, "post_missing_plugin_error", 1829);
}

fn markParsed(ev: *?*c.GstEvent) ?*c.GstEvent {
    var st = c.gst_event_get_structure(ev.*);
    if (c.gst_structure_has_field_typed(st, "urisourcebin-parsed-data", c.G_TYPE_BOOLEAN) == 0) {
        ev.* = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(ev.*)));
        st = c.gst_event_get_structure(ev.*);
        c.gst_structure_set(@constCast(st), "urisourcebin-parsed-data", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
    }
    return ev.*;
}

fn copySticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_store_sticky_event(@ptrCast(@alignCast(data)), ev.*);
    return 1;
}

fn rewriteStart(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, _: c.gpointer) callconv(.c) c.gboolean {
    if (cm.eventType(ev.*) == c.GST_EVENT_STREAM_START) {
        _ = markParsed(@ptrCast(ev));
        return 0;
    }
    return 1;
}

fn freeInfo(info: *Info, s: *Self) void {
    if (info.typefind) |t| {
        _ = c.gst_element_set_state(t, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), t);
    }
    c.gst_object_unref(info.src_pad);
    if (info.demuxer) |d| {
        _ = c.gst_element_set_state(d, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), d);
    }
    var l = info.outputs;
    while (l != null) : (l = l.*.next) freeSlot(@ptrCast(@alignCast(l.*.data)), s);
    c.g_list_free(info.outputs);
    if (info.multiqueue) |m| {
        _ = c.gst_element_set_state(m, c.GST_STATE_NULL);
        removeBufferingMsgs(s, cm.obj(m));
        _ = c.gst_bin_remove(binOf(s), m);
    }
    if (info.pre_parse_queue) |q| {
        _ = c.gst_element_set_state(q, c.GST_STATE_NULL);
        removeBufferingMsgs(s, cm.obj(q));
        _ = c.gst_bin_remove(binOf(s), q);
    }
    _ = c.gst_object_replace(@ptrCast(&info.collection), null);
    A.destroy(info);
}

fn infoFor(s: *Self, pad: ?*c.GstPad) ?*Info {
    var l = s.infos;
    while (l != null) : (l = l.*.next) {
        const i: *Info = @ptrCast(@alignCast(l.*.data));
        if (i.src_pad == pad) return i;
    }
    return null;
}

fn newInfo(s: *Self, pad: ?*c.GstPad) *Info {
    const i = A.create(Info) catch @panic("oom");
    i.* = .{ .bin = s, .src_pad = @ptrCast(@alignCast(c.gst_object_ref(pad))) };
    s.infos = c.g_list_append(s.infos, i);
    return i;
}

fn slotsOf(info: *Info) SlotIter {
    return .{ .l = info.outputs };
}

const SlotIter = struct {
    l: [*c]c.GList,
    fn next(it: *SlotIter) ?*Slot {
        const l = it.l;
        if (l == null) return null;
        it.l = l.*.next;
        return @ptrCast(@alignCast(l.*.data));
    }
};

const AllSlots = struct {
    infos: [*c]c.GList,
    cur: SlotIter = .{ .l = null },
    fn next(it: *AllSlots) ?*Slot {
        while (true) {
            if (it.cur.next()) |x| return x;
            const l = it.infos;
            if (l == null) return null;
            it.infos = l.*.next;
            it.cur = slotsOf(@ptrCast(@alignCast(l.*.data)));
        }
    }
};

fn allSlots(s: *Self) AllSlots {
    return .{ .infos = s.infos };
}

fn replacementSlot(info: *Info, stream: ?*c.GstStream) ?*Slot {
    var it = slotsOf(info);
    while (it.next()) |x| if (x.pending_stream == stream) return x;
    return null;
}

fn demuxPadAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const info: *Info = @ptrCast(@alignCast(data));
    const s = info.bin;
    lock(s);
    if (info.demuxer != null and !info.is_parsebin and !info.streams_aware)
        coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("Adaptive demuxer is not streams-aware, check your installation"), "new_demuxer_pad_added_cb", 879);
    if (info.is_parsebin) {
        if (c.gst_pad_get_stream(pad)) |stream| {
            const slot = replacementSlot(info, stream);
            c.gst_object_unref(stream);
            if (slot) |x| {
                x.pending_pad = @ptrCast(@alignCast(c.gst_object_ref(pad)));
                x.pending_probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH, demuxEvents, x, null);
                unlock(s);
                return;
            }
        }
    }
    const slot = newSlot(info, pad) orelse {
        unlock(s);
        return;
    };
    const out = c.gst_object_ref(slot.output);
    unlock(s);
    expose(s, @ptrCast(@alignCast(out)));
    c.gst_object_unref(out);
}

fn allEos(s: *Self) bool {
    var it = allSlots(s);
    while (it.next()) |x| if (!x.is_eos) return false;
    return true;
}

fn slotForOrigin(info: *Info, pad: ?*c.GstPad) ?*Slot {
    var it = slotsOf(info);
    while (it.next()) |x| if (x.origin == pad) return x;
    return null;
}

fn demuxEvents(pad: ?*c.GstPad, pi: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const slot: *Slot = @ptrCast(@alignCast(data));
    const s = slot.info.bin;
    var ev: ?*c.GstEvent = @ptrCast(@alignCast(pi.*.data));
    lock(s);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_EOS => {
            if (slot.pending_pad != null and pad != slot.pending_pad) {
                unlock(s);
                return c.GST_PAD_PROBE_DROP;
            }
            bufLock(s);
            slot.is_eos = true;
            const all = allEos(s);
            bufUnlock(s);
            if (slot.queue) |q| removeBufferingMsgs(s, cm.obj(q));
            unlock(s);
            if (all) c.g_signal_emit(s, signals[SIG_ABOUT_TO_FINISH], 0);
            return c.GST_PAD_PROBE_OK;
        },
        c.GST_EVENT_STREAM_START, c.GST_EVENT_FLUSH_STOP => {
            if (cm.eventType(ev) == c.GST_EVENT_STREAM_START and (s.is_adaptive != 0 or slot.info.is_parsebin)) pi.*.data = markParsed(&ev);
            bufLock(s);
            slot.is_eos = false;
            bufUnlock(s);
        },
        else => {},
    }
    unlock(s);
    return c.GST_PAD_PROBE_OK;
}

fn preQueueEvent(_: ?*c.GstPad, pi: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (cm.eventType(pi.*.data) == c.GST_EVENT_EOS) c.g_signal_emit(data, signals[SIG_ABOUT_TO_FINISH], 0);
    return c.GST_PAD_PROBE_OK;
}

fn statistics(s: *Self) ?*c.GstStructure {
    var have = false;
    var min_b: c.guint = std.math.maxInt(u32);
    var max_b: c.guint = 0;
    var min_t: u64 = std.math.maxInt(u64);
    var max_t: u64 = 0;
    var avg_b: f64 = 0;
    var avg_t: f64 = 0;
    var i: f64 = 0;
    lock(s);
    var it = allSlots(s);
    while (it.next()) |x| {
        const q = x.queue orelse continue;
        var b: c.guint = 0;
        var t: u64 = 0;
        c.g_object_get(gobj(q), "current-level-bytes", &b, "current-level-time", &t, N);
        have = true;
        min_b = @min(min_b, b);
        max_b = @max(max_b, b);
        avg_b = (avg_b * i + @as(f64, @floatFromInt(b))) / (i + 1);
        min_t = @min(min_t, t);
        max_t = @max(max_t, t);
        avg_t = (avg_t * i + @as(f64, @floatFromInt(t))) / (i + 1);
        i += 1;
    }
    unlock(s);
    if (!have) {
        min_b = 0;
        min_t = 0;
    }
    return c.gst_structure_new("application/x-urisourcebin-stats", "minimum-byte-level", c.G_TYPE_UINT, min_b, "maximum-byte-level", c.G_TYPE_UINT, max_b, "average-byte-level", c.G_TYPE_UINT, @as(c.guint, @intFromFloat(avg_b)), "minimum-time-level", c.G_TYPE_UINT64, min_t, "maximum-time-level", c.G_TYPE_UINT64, max_t, "average-time-level", c.G_TYPE_UINT64, @as(u64, @intFromFloat(avg_t)), N);
}

fn updateQueues(s: *Self) void {
    lock(s);
    defer unlock(s);
    const duration = bufDuration(s);
    const size = bufSize(s);
    var total: u64 = 0;
    var li = s.infos;
    scan: while (li != null) : (li = li.*.next) {
        var si = slotsOf(@ptrCast(@alignCast(li.*.data)));
        while (si.next()) |x| {
            const q = x.queue orelse continue;
            var br: u64 = 0;
            if (hasProp(q, "bitrate") != null) c.g_object_get(gobj(q), "bitrate", &br, N);
            if (br > 0) {
                total += br;
            } else {
                total = 0;
                continue :scan;
            }
        }
    }
    var it = allSlots(s);
    while (it.next()) |x| {
        const q = x.queue orelse continue;
        var limit = size;
        if (total > 0 and hasProp(q, "bitrate") != null) {
            var br: u64 = 0;
            c.g_object_get(gobj(q), "bitrate", &br, N);
            limit = @intCast(c.gst_util_uint64_scale(size, br, total));
        }
        c.g_object_set(gobj(q), "max-size-bytes", limit, "max-size-time", @as(u64, @bitCast(duration)), "low-watermark", s.low, "high-watermark", s.high, N);
    }
}

fn updateQueuesAsync(o: ?*c.GstObject, _: c.gpointer) callconv(.c) void {
    updateQueues(me(o));
}

fn bitrateChanged(_: ?*c.GstElement, _: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    c.gst_object_call_async(cm.obj(data), updateQueuesAsync, null);
}

fn setupDownloadbuffer(s: *Self, db: ?*c.GstElement) void {
    var dir: [*c]const u8 = undefined;
    if (s.download_dir != null) {
        dir = s.download_dir;
        if (c.g_mkdir_with_parents(dir, 0o700) != 0)
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, c.g_strdup_printf(tr("Failed to create download directory '%s'."), dir), c.g_strdup_printf("%s", c.g_strerror(std.c._errno().*)), FILE, "setup_downloadbuffer", 1201);
    } else dir = c.g_get_user_cache_dir();
    var prg = c.g_get_prgname();
    if (prg == null) prg = "GStreamer";
    const name = c.g_strdup_printf("%s-XXXXXX", prg);
    const tmpl = c.g_build_filename(dir, name, N);
    c.g_object_set(gobj(db), "temp-template", tmpl, N);
    c.g_free(name);
    c.g_free(tmpl);
}

fn setupMultiqueue(s: *Self, info: *Info) void {
    const mq = info.multiqueue;
    if (info.use_downloadbuffer or s.is_stream == 0) {
        c.g_object_set(gobj(mq), "use-buffering", @as(c.gboolean, 0), N);
    } else {
        c.g_object_set(gobj(mq), "use-buffering", @as(c.gboolean, 1), "min-interleave-time", @as(u64, @bitCast(bufDuration(s))), N);
    }
    c.g_object_set(gobj(mq), "sync-by-running-time", @as(c.gboolean, 1), "use-interleave", @as(c.gboolean, 1), "max-size-bytes", @as(c.guint, 0), "max-size-buffers", @as(c.guint, 0), "low-watermark", s.low, "high-watermark", s.high, N);
    _ = c.gst_bin_add(binOf(s), mq);
    _ = c.gst_element_sync_state_with_parent(mq);
}

fn newSlot(info: *Info, origin: ?*c.GstPad) ?*Slot {
    const s = info.bin;
    const slot = A.create(Slot) catch @panic("oom");
    slot.* = .{ .info = info };
    const use_db = info.use_downloadbuffer and info.demuxer == null;
    if (s.parse_streams != 0 and (info.use_queue2 or info.use_downloadbuffer or s.is_stream == 0)) {
        if (info.multiqueue == null) {
            info.multiqueue = c.gst_element_factory_make("multiqueue", null);
            if (info.multiqueue == null) {
                A.destroy(slot);
                missingPlugin(s, "multiqueue");
                return null;
            }
            setupMultiqueue(s, info);
        }
        slot.queue_sink = c.gst_element_request_pad_simple(info.multiqueue, "sink_%u");
        const src = c.gst_pad_get_single_internal_link(slot.queue_sink);
        if (s.is_adaptive != 0 or info.is_parsebin) _ = c.gst_pad_sticky_events_foreach(origin, rewriteStart, null);
        if (info.demuxer != null) slot.demux_probe = c.gst_pad_add_probe(origin, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH, demuxEvents, slot, null);
        slot.output = createOutput(slot, src);
        c.gst_object_unref(src);
        _ = c.gst_pad_link(origin, slot.queue_sink);
    } else if (use_db or info.use_queue2) {
        const name: [*c]const u8 = if (use_db) "downloadbuffer" else "queue2";
        const q = c.gst_element_factory_make(name, null) orelse {
            A.destroy(slot);
            missingPlugin(s, name);
            return null;
        };
        slot.queue = q;
        slot.bitrate_id = c.g_signal_connect_data(q, "notify::bitrate", @ptrCast(&bitrateChanged), s, null, 0);
        if (use_db) {
            setupDownloadbuffer(s, q);
        } else {
            c.g_object_set(gobj(q), "use-buffering", s.use_buffering, N);
            if (info.demuxer != null) {
                c.g_object_set(gobj(q), "use-tags-bitrate", @as(c.gboolean, 1), "use-rate-estimate", @as(c.gboolean, 0), N);
            } else c.g_object_set(gobj(q), "ring-buffer-max-size", s.ring_max, N);
            c.g_object_set(gobj(q), "max-size-buffers", @as(c.guint, 0), N);
            c.g_object_set(gobj(q), "low-percent", @as(c.gint, 1), "high-percent", @as(c.gint, 60), N);
            c.g_object_set(gobj(q), "low-watermark", s.low, "high-watermark", s.high, N);
        }
        c.g_object_set(gobj(q), "max-size-bytes", bufSize(s), "max-size-time", @as(u64, @bitCast(bufDuration(s))), N);
        _ = c.gst_bin_add(binOf(s), q);
        _ = c.gst_element_sync_state_with_parent(q);
        slot.queue_sink = c.gst_element_get_static_pad(q, "sink");
        const src = c.gst_element_get_static_pad(q, "src");
        slot.output = createOutput(slot, src);
        c.gst_object_unref(src);
        _ = c.gst_pad_link(origin, slot.queue_sink);
    } else {
        if (info.demuxer != null) slot.demux_probe = c.gst_pad_add_probe(origin, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM | c.GST_PAD_PROBE_TYPE_EVENT_FLUSH, demuxEvents, slot, null);
        slot.output = createOutput(slot, origin);
    }
    slot.origin = @ptrCast(@alignCast(c.gst_object_ref(origin)));
    slot.stream = c.gst_pad_get_stream(origin);
    info.outputs = c.g_list_append(info.outputs, slot);
    return slot;
}

fn sourcePadEvent(_: ?*c.GstPad, pi: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(pi.*.data));
    const slot: *Slot = @ptrCast(@alignCast(data));
    const s = slot.info.bin;
    if (cm.eventType(ev) != c.GST_EVENT_EOS or c.gst_mini_object_get_qdata(@ptrCast(ev), eosQuark()) == null) return c.GST_PAD_PROBE_OK;
    c.gst_mini_object_set_qdata(@ptrCast(ev), eosQuark(), null, null);
    var r: c.GstPadProbeReturn = c.GST_PAD_PROBE_DROP;
    lock(s);
    if (slot.is_eos) {
        _ = c.gst_pad_push_event(slot.output, ev);
        r = c.GST_PAD_PROBE_HANDLED;
    }
    freeSlotAsync(s, slot);
    unlock(s);
    return r;
}

fn createOutput(slot: *Slot, pad: ?*c.GstPad) ?*c.GstPad {
    const s = slot.info.bin;
    if (slot.queue != null) _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, sourcePadEvent, slot, null);
    const tmpl = c.gst_static_pad_template_get(&src_t);
    const name = c.g_strdup_printf("src_%u", s.numpads);
    s.numpads += 1;
    const p = c.gst_ghost_pad_new_from_template(name, pad, tmpl);
    c.gst_object_unref(tmpl);
    c.g_free(name);
    return p;
}

fn exposeBlock(pad: ?*c.GstPad, _: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    lock(s);
    while (s.activated == 0 and @atomicLoad(c.gint, &s.flushing, .seq_cst) == 0) c.g_cond_wait(&s.activation, &s.lock);
    const go = @atomicLoad(c.gint, &s.flushing, .seq_cst) == 0;
    unlock(s);
    if (go) _ = c.gst_element_add_pad(elem(s), pad);
    return c.GST_PAD_PROBE_REMOVE;
}

fn expose(s: *Self, pad: ?*c.GstPad) void {
    if (c.gst_object_has_as_parent(cm.obj(pad), cm.obj(s)) != 0) return;
    const target = c.gst_ghost_pad_get_target(ghost(pad));
    _ = c.gst_pad_set_active(pad, 1);
    _ = c.gst_pad_sticky_events_foreach(target, copySticky, pad);
    c.gst_object_unref(target);
    lock(s);
    const now = s.activated != 0;
    if (!now) _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, exposeBlock, s, null);
    unlock(s);
    if (now) _ = c.gst_element_add_pad(elem(s), pad);
}

fn demuxPadRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) != c.GST_PAD_SRC) return;
    const info: *Info = @ptrCast(@alignCast(data));
    const s = info.bin;
    lock(s);
    defer unlock(s);
    const slot = slotForOrigin(info, pad) orelse return;
    if (slot.demux_probe != 0) {
        c.gst_pad_remove_probe(pad, slot.demux_probe);
        slot.demux_probe = 0;
    }
    if (slot.pending_pad) |pp| {
        slot.demux_probe = slot.pending_probe;
        slot.pending_probe = 0;
        c.gst_object_unref(slot.origin);
        slot.origin = pp;
        slot.pending_pad = null;
        if (slot.stream) |x| c.gst_object_unref(x);
        slot.stream = slot.pending_stream;
        slot.pending_stream = null;
        if (slot.queue_sink != null) {
            _ = c.gst_pad_link(slot.origin, slot.queue_sink);
        } else _ = c.gst_ghost_pad_set_target(ghost(slot.output), slot.origin);
        return;
    }
    if (slot.queue) |q| {
        bufLock(s);
        const was = slot.is_eos;
        slot.is_eos = true;
        bufUnlock(s);
        removeBufferingMsgs(s, cm.obj(q));
        if (!was) {
            const ev = c.gst_event_new_eos();
            c.gst_structure_set(c.gst_event_writable_structure(ev), "urisourcebin-custom-eos", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), N);
            _ = c.gst_pad_send_event(slot.queue_sink, ev);
        }
    } else {
        info.outputs = c.g_list_remove(info.outputs, slot);
        freeSlot(slot, s);
    }
}

const stream_uris = [_][]const u8{ "http://", "https://", "mms://", "mmsh://", "mmsu://", "mmst://", "fd://", "myth://", "ssh://", "ftp://", "sftp://" };
const queue_uris = [_][]const u8{"cdda://"};
const adaptive_media = [_][]const u8{ "application/x-hls", "application/vnd.ms-sstr+xml", "application/dash+xml" };

fn uriIn(list: []const []const u8, uri: [*c]const u8) bool {
    if (uri == null) return false;
    for (list) |p| if (c.g_ascii_strncasecmp(uri, p.ptr, p.len) == 0) return true;
    return false;
}

fn isAdaptive(media: [*c]const u8) bool {
    const m = std.mem.span(media);
    for (adaptive_media) |p| if (std.mem.startsWith(u8, m, p)) return true;
    return false;
}

fn clampSpeed(spec: *c.GParamSpec, speed: u64) ?c.GValue {
    var v = std.mem.zeroes(c.GValue);
    const t = spec.g_type_instance.g_class.*.g_type;
    if (t == c.G_TYPE_PARAM_UINT()) {
        const p: *c.GParamSpecUInt = @ptrCast(@alignCast(spec));
        _ = c.g_value_init(&v, c.G_TYPE_UINT64);
        c.g_value_set_uint64(&v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT()) {
        const p: *c.GParamSpecInt = @ptrCast(@alignCast(spec));
        _ = c.g_value_init(&v, c.G_TYPE_UINT64);
        const lo: u64 = @bitCast(@as(i64, p.minimum));
        const hi: u64 = @bitCast(@as(i64, p.maximum));
        c.g_value_set_uint64(&v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else if (t == c.G_TYPE_PARAM_UINT64()) {
        const p: *c.GParamSpecUInt64 = @ptrCast(@alignCast(spec));
        _ = c.g_value_init(&v, c.G_TYPE_UINT64);
        c.g_value_set_uint64(&v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT64()) {
        const p: *c.GParamSpecInt64 = @ptrCast(@alignCast(spec));
        _ = c.g_value_init(&v, c.G_TYPE_UINT64);
        const lo: u64 = @bitCast(p.minimum);
        const hi: u64 = @bitCast(p.maximum);
        c.g_value_set_uint64(&v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else return null;
    return v;
}

fn genSource(s: *Self) ?*c.GstElement {
    if (s.uri == null) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(tr("No URI specified to play from.")), null, FILE, "gen_source_element", 1749);
        return null;
    }
    if (c.gst_uri_is_valid(s.uri) == 0) return invalidUri(s);
    var err: [*c]c.GError = null;
    const source = c.gst_element_make_from_uri(c.GST_URI_SRC, s.uri, null, &err) orelse {
        defer c.g_clear_error(&err);
        if (err != null and err.*.code == c.GST_URI_ERROR_UNSUPPORTED_PROTOCOL) {
            const prot = c.gst_uri_get_protocol(s.uri);
            if (prot == null) return invalidUri(s);
            _ = c.gst_element_post_message(elem(s), c.gst_missing_uri_source_message_new(elem(s), prot));
            coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(tr("No URI handler implemented for \"%s\"."), prot), null, "gen_source_element", 1780);
            c.g_free(prot);
        } else {
            cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("%s", if (err != null) @as([*c]const u8, err.*.message) else @as([*c]const u8, "URI was not accepted by any element")), c.g_strdup_printf("No element accepted URI '%s'", s.uri), FILE, "gen_source_element", 1785);
        }
        return null;
    };
    if (hasProp(source, "connection-speed")) |spec| {
        if (clampSpeed(spec, s.speed / 1000)) |val| {
            var v = val;
            c.g_object_set_property(gobj(source), "connection-speed", &v);
            c.g_value_unset(&v);
        }
    }
    return source;
}

fn invalidUri(s: *Self) ?*c.GstElement {
    cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("Invalid URI \"%s\"."), s.uri), null, FILE, "gen_source_element", 1755);
    return null;
}

fn allRaw(caps: [*c]c.GstCaps, raw: *bool) bool {
    if (caps == null) return false;
    const size = c.gst_caps_get_size(caps);
    if (size == 0 or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) return false;
    const rc = utils.rawCaps();
    defer c.gst_caps_unref(rc);
    const inter = c.gst_caps_intersect(caps, rc);
    raw.* = c.gst_caps_is_empty(inter) == 0 and c.gst_caps_get_size(inter) == size;
    c.gst_caps_unref(inter);
    return true;
}

fn exposeSlot(s: *Self, slot: *Slot) void {
    const out = c.gst_object_ref(slot.output);
    unlock(s);
    expose(s, @ptrCast(@alignCast(out)));
    c.gst_object_unref(out);
}

fn analysePad(s: *Self, pad: ?*c.GstPad, have_out: *bool) bool {
    have_out.* = true;
    if (infoFor(s, pad) != null) return true;
    const info = newInfo(s, pad);
    const caps = c.gst_pad_query_caps(pad, null);
    defer if (caps != null) c.gst_caps_unref(caps);
    var raw = false;
    if (!allRaw(caps, &raw) or !raw) return setupTypefind(info);
    lock(s);
    info.use_queue2 = s.use_buffering != 0 and uriIn(&queue_uris, s.uri);
    const slot = newSlot(info, pad) orelse {
        unlock(s);
        return false;
    };
    exposeSlot(s, slot);
    return true;
}

fn analyseSource(s: *Self, have_out: *bool, dynamic: *bool) bool {
    s.is_stream = @intFromBool(uriIn(&stream_uris, s.uri));
    if (s.is_stream == 0) {
        const q = c.gst_query_new_scheduling();
        if (c.gst_element_query(s.source, q) != 0) {
            var fl: c.GstSchedulingFlags = 0;
            c.gst_query_parse_scheduling(q, &fl, null, null, null);
            if ((fl & c.GST_SCHEDULING_FLAG_BANDWIDTH_LIMITED) != 0) s.is_stream = 1;
        }
        c.gst_query_unref(q);
    }
    if (s.is_stream != 0) {
        if (hasProp(s.source, "is-live")) |spec| {
            if (spec.*.value_type == c.G_TYPE_BOOLEAN) {
                var live: c.gboolean = 0;
                c.g_object_get(gobj(s.source), "is-live", &live, N);
                if (live != 0) s.is_stream = 0;
            }
        }
    }
    const it = c.gst_element_iterate_src_pads(s.source);
    var res = true;
    var out = false;
    var item = std.mem.zeroes(c.GValue);
    restart: while (true) {
        res = true;
        out = false;
        while (true) {
            switch (c.gst_iterator_next(it, &item)) {
                c.GST_ITERATOR_OK => {
                    const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
                    _ = c.g_value_reset(&item);
                    res = analysePad(s, pad, &out) and res;
                    c.gst_object_unref(pad);
                },
                c.GST_ITERATOR_RESYNC => {
                    c.gst_iterator_resync(it);
                    continue :restart;
                },
                c.GST_ITERATOR_ERROR => {
                    res = false;
                    break :restart;
                },
                else => break :restart,
            }
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    dynamic.* = false;
    var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(gobj(s.source).g_type_instance.g_class)));
    while (l != null) : (l = l.*.next) {
        const t: *c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t.direction == c.GST_PAD_SRC) {
            if (t.presence == c.GST_PAD_SOMETIMES) dynamic.* = true;
            break;
        }
    }
    have_out.* = out;
    return res;
}

fn makeDemuxer(s: *Self, info: *Info, caps: [*c]c.GstCaps) ?*c.GstElement {
    const all = c.gst_element_factory_list_get_elements(c.GST_ELEMENT_FACTORY_TYPE_DEMUXER, c.GST_RANK_MARGINAL);
    var ok = c.gst_element_factory_list_filter(all, caps, c.GST_PAD_SINK, c.gst_caps_is_fixed(caps));
    c.gst_plugin_feature_list_free(all);
    var demuxer: ?*c.GstElement = null;
    if (ok != null) {
        ok = c.g_list_sort(ok, c.gst_plugin_feature_rank_compare_func);
        var l = ok;
        while (l != null) : (l = l.*.next) {
            const f: ?*c.GstElementFactory = @ptrCast(@alignCast(l.*.data));
            const klass = c.gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS);
            if (c.strstr(klass, "Demux") == null or c.strstr(klass, "Adaptive") == null) continue;
            demuxer = c.gst_element_factory_create(f, null);
            break;
        }
        c.gst_plugin_feature_list_free(ok);
    }
    const d = demuxer orelse {
        coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No demuxer element, check your installation"), "make_demuxer", 2083);
        return null;
    };
    _ = c.g_signal_connect_data(d, "pad-added", @ptrCast(&demuxPadAdded), info, null, 0);
    _ = c.g_signal_connect_data(d, "pad-removed", @ptrCast(&demuxPadRemoved), info, null, 0);
    if (hasProp(d, "connection-speed") != null) c.g_object_set(gobj(d), "connection-speed", s.speed / 1000, N);
    return d;
}

fn parsebinLinkFailed(s: *Self, info: *Info) bool {
    if (info.demuxer) |d| _ = c.gst_element_set_locked_state(d, 0);
    unlock(s);
    coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Can't link to (pre-)parsebin element"), "setup_parsebin_for_slot", 2185);
    return false;
}

fn setupParsebin(info: *Info, origin: ?*c.GstPad) bool {
    const s = info.bin;
    if (@atomicLoad(c.gint, &s.flushing, .seq_cst) != 0) return false;
    lock(s);
    if (info.use_downloadbuffer or s.ring_max != 0) {
        if (info.use_downloadbuffer) {
            info.pre_parse_queue = c.gst_element_factory_make("downloadbuffer", null);
            setupDownloadbuffer(s, info.pre_parse_queue);
            c.g_object_set(gobj(info.pre_parse_queue), "max-size-bytes", bufSize(s), "max-size-time", @as(u64, @bitCast(bufDuration(s))), N);
        } else {
            info.pre_parse_queue = c.gst_element_factory_make("queue2", null);
            c.g_object_set(gobj(info.pre_parse_queue), "use-buffering", @as(c.gboolean, 0), "ring-buffer-max-size", s.ring_max, "max-size-buffers", @as(c.guint, 0), N);
        }
        _ = c.gst_bin_add(binOf(s), info.pre_parse_queue);
        const sink = c.gst_element_get_static_pad(info.pre_parse_queue, "sink");
        const r = c.gst_pad_link(origin, sink);
        c.gst_object_unref(sink);
        if (r != c.GST_PAD_LINK_OK) return parsebinLinkFailed(s, info);
    }
    info.demuxer = c.gst_element_factory_make("parsebin", null);
    if (info.demuxer == null) {
        unlock(s);
        missingPlugin(s, "parsebin");
        return false;
    }
    _ = c.gst_element_set_locked_state(info.demuxer, 1);
    _ = c.gst_bin_add(binOf(s), info.demuxer);
    info.is_parsebin = true;
    if (info.pre_parse_queue) |q| {
        if (c.gst_element_link_pads(q, "src", info.demuxer, "sink") == 0) return parsebinLinkFailed(s, info);
    } else {
        const sink = c.gst_element_get_static_pad(info.demuxer, "sink");
        const r = c.gst_pad_link(origin, sink);
        c.gst_object_unref(sink);
        if (r != c.GST_PAD_LINK_OK) return parsebinLinkFailed(s, info);
    }
    _ = c.g_signal_connect_data(info.demuxer, "pad-added", @ptrCast(&demuxPadAdded), info, null, 0);
    _ = c.g_signal_connect_data(info.demuxer, "pad-removed", @ptrCast(&demuxPadRemoved), info, null, 0);
    if (info.pre_parse_queue) |q| _ = c.gst_element_sync_state_with_parent(q);
    _ = c.gst_element_set_locked_state(info.demuxer, 0);
    _ = c.gst_element_sync_state_with_parent(info.demuxer);
    unlock(s);
    return true;
}

fn handleNewPad(info: *Info, pad: ?*c.GstPad, caps: [*c]c.GstCaps) void {
    const s = info.bin;
    lock(s);
    var raw = false;
    if (allRaw(caps, &raw) and raw) {
        const slot = newSlot(info, pad) orelse return unlock(s);
        return exposeSlot(s, slot);
    }
    unlock(s);
    const media = c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0));
    s.is_adaptive = @intFromBool(isAdaptive(media));
    if (s.is_adaptive != 0) {
        info.demuxer = makeDemuxer(s, info, caps) orelse return;
        _ = c.gst_bin_add(binOf(s), info.demuxer);
        const q = c.gst_query_new_buffering(c.GST_FORMAT_TIME);
        info.use_queue2 = s.use_buffering != 0 and c.gst_element_query(info.demuxer, q) == 0;
        c.gst_query_unref(q);
        const sink = c.gst_element_get_static_pad(info.demuxer, "sink") orelse {
            coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Adaptive demuxer element has no 'sink' pad"), "handle_new_pad", 2318);
            return;
        };
        const r = c.gst_pad_link(pad, sink);
        c.gst_object_unref(sink);
        if (r != c.GST_PAD_LINK_OK) {
            coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Can't link typefind to adaptive demuxer element"), "handle_new_pad", 2325);
            return;
        }
        _ = c.gst_element_sync_state_with_parent(info.demuxer);
        return;
    }
    if (s.is_stream == 0) {
        if (s.parse_streams != 0) {
            _ = setupParsebin(info, pad);
            return;
        }
        lock(s);
        const slot = newSlot(info, pad) orelse return unlock(s);
        return exposeSlot(s, slot);
    }
    if (s.download != 0) {
        const q = c.gst_query_new_duration(c.GST_FORMAT_BYTES);
        if (c.gst_pad_query(pad, q) != 0) {
            var dur: i64 = 0;
            c.gst_query_parse_duration(q, null, &dur);
            info.use_downloadbuffer = dur != -1;
        }
        c.gst_query_unref(q);
    }
    info.use_queue2 = s.use_buffering != 0;
    if (s.parse_streams != 0) {
        _ = setupParsebin(info, pad);
        return;
    }
    lock(s);
    const slot = newSlot(info, pad) orelse return unlock(s);
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, preQueueEvent, s, null);
    exposeSlot(s, slot);
}

fn typeFound(tf: ?*c.GstElement, _: c.guint, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    const pad = c.gst_element_get_static_pad(tf, "src");
    handleNewPad(@ptrCast(@alignCast(data)), pad, caps);
    c.gst_object_unref(pad);
}

fn setupTypefind(info: *Info) bool {
    const s = info.bin;
    info.typefind = c.gst_element_factory_make("typefind", null) orelse {
        missingPlugin(s, "typefind");
        coreError(s, c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No typefind element, check your installation"), "setup_typefind", 2385);
        return false;
    };
    _ = c.gst_element_set_locked_state(info.typefind, 1);
    _ = c.gst_bin_add(binOf(s), info.typefind);
    const sink = c.gst_element_get_static_pad(info.typefind, "sink");
    defer c.gst_object_unref(sink);
    if (c.gst_pad_link(info.src_pad, sink) != c.GST_PAD_LINK_OK) {
        _ = c.gst_element_set_locked_state(info.typefind, 0);
        coreError(s, c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Can't link source to typefind element"), "setup_typefind", 2393);
        return false;
    }
    _ = c.g_signal_connect_data(info.typefind, "have-type", @ptrCast(&typeFound), info, null, 0);
    _ = c.gst_element_set_locked_state(info.typefind, 0);
    _ = c.gst_element_sync_state_with_parent(info.typefind);
    return true;
}

fn freeSlot(slot: *Slot, s: *Self) void {
    if (slot.queue) |q| {
        if (slot.bitrate_id > 0) c.g_signal_handler_disconnect(q, slot.bitrate_id);
        slot.bitrate_id = 0;
        _ = c.gst_element_set_locked_state(q, 1);
        _ = c.gst_element_set_state(q, c.GST_STATE_NULL);
        removeBufferingMsgs(s, cm.obj(q));
        _ = c.gst_bin_remove(binOf(s), q);
    }
    if (slot.queue_sink) |p| {
        if (slot.info.multiqueue) |m| c.gst_element_release_request_pad(m, p);
        c.gst_object_unref(p);
        slot.queue_sink = null;
    }
    if (slot.demux_probe != 0) c.gst_pad_remove_probe(slot.origin, slot.demux_probe);
    if (slot.pending_pad) |pp| {
        if (slot.pending_probe != 0) c.gst_pad_remove_probe(pp, slot.pending_probe);
        c.gst_object_unref(pp);
    }
    if (slot.stream) |x| c.gst_object_unref(x);
    if (slot.pending_stream) |x| c.gst_object_unref(x);
    c.gst_object_unref(slot.origin);
    _ = c.gst_pad_set_active(slot.output, 0);
    _ = c.gst_element_remove_pad(elem(s), slot.output);
    A.destroy(slot);
}

fn freeSlotCall(o: ?*c.GstObject, data: c.gpointer) callconv(.c) void {
    freeSlot(@ptrCast(@alignCast(data)), me(o));
}

fn freeSlotAsync(s: *Self, slot: *Slot) void {
    slot.info.outputs = c.g_list_remove(slot.info.outputs, slot);
    c.gst_object_call_async(cm.obj(s), freeSlotCall, slot);
}

fn removeSource(s: *Self) void {
    if (s.source) |src| {
        _ = c.gst_element_set_state(src, c.GST_STATE_NULL);
        if (s.np_id != 0) {
            c.g_signal_handler_disconnect(src, s.np_id);
            s.np_id = 0;
        }
        _ = c.gst_bin_remove(binOf(s), src);
        s.source = null;
    }
    lock(s);
    var l = s.infos;
    while (l != null) : (l = l.*.next) freeInfo(@ptrCast(@alignCast(l.*.data)), s);
    c.g_list_free(s.infos);
    s.infos = null;
    unlock(s);
}

fn sourceNewPad(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const info = newInfo(s, pad);
    const caps = c.gst_pad_get_current_caps(pad);
    if (caps == null) {
        _ = setupTypefind(info);
    } else {
        handleNewPad(info, pad, caps);
        c.gst_caps_unref(caps);
    }
}

fn setupSource(s: *Self) bool {
    s.source = genSource(s) orelse return false;
    _ = c.gst_bin_add(binOf(s), s.source);
    c.g_object_notify(gobj(s), "source");
    c.g_signal_emit(s, signals[SIG_SOURCE_SETUP], 0, s.source);
    if (c.gst_element_set_state(s.source, c.GST_STATE_READY) != c.GST_STATE_CHANGE_SUCCESS) {
        coreError(s, c.GST_CORE_ERROR_FAILED, c.g_strdup(tr("Source element can't be prepared")), null, "setup_source", 2570);
        return false;
    }
    var have_out = false;
    var dynamic = false;
    if (!analyseSource(s, &have_out, &dynamic)) {
        coreError(s, c.GST_CORE_ERROR_FAILED, c.g_strdup(tr("Source element is invalid.")), null, "setup_source", 2564);
        return false;
    }
    if (!dynamic) {
        if (!have_out) {
            coreError(s, c.GST_CORE_ERROR_FAILED, c.g_strdup(tr("Source element has no pads.")), null, "setup_source", 2576);
            return false;
        }
    } else s.np_id = c.g_signal_connect_data(s.source, "pad-added", @ptrCast(&sourceNewPad), s, null, 0);
    return true;
}

fn appendStructures(list: *c.GValue, first: *?*c.GstStructure, items: [*c]c.GList) void {
    var l = items;
    while (l != null) : (l = l.*.next) {
        const st: ?*c.GstStructure = @ptrCast(@alignCast(l.*.data));
        if (first.* == null) first.* = c.gst_structure_copy(st);
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_structure_get_type());
        c.g_value_take_boxed(&v, c.gst_structure_copy(st));
        c.gst_value_list_append_value(list, &v);
        c.g_value_unset(&v);
    }
}

fn redirect(s: *Self, msg: [*c]c.GstMessage) [*c]c.GstMessage {
    const st = c.gst_message_get_structure(msg);
    if (s.speed == 0 or st == null) return msg;
    const locs = c.gst_structure_get_value(st, "locations") orelse return msg;
    const size = c.gst_value_list_get_size(locs);
    if (size < 2) return msg;
    var good: [*c]c.GList = null;
    var neutral: [*c]c.GList = null;
    var bad: [*c]c.GList = null;
    var i: c.guint = 0;
    while (i < size) : (i += 1) {
        const x: ?*const c.GstStructure = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_value_list_get_value(locs, i))));
        var br: c.gint = 0;
        if (c.gst_structure_get_int(x, "minimum-bitrate", &br) == 0 or br <= 0) {
            neutral = c.g_list_append(neutral, @constCast(x));
        } else if (@as(u64, @intCast(br)) > s.speed) {
            bad = c.g_list_append(bad, @constCast(x));
        } else good = c.g_list_append(good, @constCast(x));
    }
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var first: ?*c.GstStructure = null;
    appendStructures(&list, &first, good);
    appendStructures(&list, &first, neutral);
    appendStructures(&list, &first, bad);
    c.gst_structure_take_value(first, "locations", &list);
    c.g_list_free(good);
    c.g_list_free(neutral);
    c.g_list_free(bad);
    const n = c.gst_message_new_element(msg.*.src, first);
    c.gst_message_unref(msg);
    return n;
}

fn slotForQueue(s: *Self, e: ?*c.GstObject) ?*Slot {
    var it = allSlots(s);
    while (it.next()) |x| if (x.queue != null and cm.obj(x.queue) == e) return x;
    return null;
}

fn handleBuffering(s: *Self, msg_in: [*c]c.GstMessage) void {
    var msg = msg_in;
    var pct: c.gint = 0;
    c.gst_message_parse_buffering(msg, &pct);
    bufLock(s);
    if (slotForQueue(s, msg.*.src)) |x| if (x.is_eos) {
        bufUnlock(s);
        c.gst_message_unref(msg);
        return;
    };
    c.g_mutex_lock(&s.post_lock);
    var smaller_pct: c.gint = 100;
    var smaller: [*c]c.GstMessage = null;
    var found = false;
    var l = s.buffering;
    while (l != null) {
        var stats: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        var eos = false;
        if (slotForQueue(s, msg.*.src)) |x| eos = x.is_eos;
        if (stats.*.src == msg.*.src) {
            found = true;
            if (pct < 100) {
                c.gst_message_unref(stats);
                stats = c.gst_message_ref(msg);
                l.*.data = stats;
            } else {
                const cur = l;
                l = l.*.next;
                c.gst_message_unref(stats);
                s.buffering = c.g_list_delete_link(s.buffering, cur);
                continue;
            }
        }
        if (!eos) {
            var p: c.gint = 0;
            c.gst_message_parse_buffering(stats, &p);
            if (p < smaller_pct) {
                smaller_pct = p;
                smaller = stats;
            }
        }
        l = l.*.next;
    }
    if (!found and pct < 100) {
        if (pct < smaller_pct) {
            smaller_pct = pct;
            smaller = msg;
        }
        s.buffering = c.g_list_prepend(s.buffering, c.gst_message_ref(msg));
    }
    if (smaller_pct == s.last_pct) {
        c.gst_message_unref(msg);
        msg = null;
    } else {
        s.last_pct = smaller_pct;
        if (smaller_pct != 100) {
            const keep = c.gst_message_ref(smaller);
            c.gst_message_unref(msg);
            msg = keep;
        }
    }
    bufUnlock(s);
    if (msg != null) parent_class.?.handle_message.?(binOf(s), msg);
    c.g_mutex_unlock(&s.post_lock);
}

fn removeBufferingMsgs(s: *Self, src: ?*c.GstObject) void {
    bufLock(s);
    c.g_mutex_lock(&s.post_lock);
    var removed = false;
    var l = s.buffering;
    while (l != null) : (l = l.*.next) {
        const stats: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
        if (stats.*.src == src) {
            c.gst_message_unref(stats);
            s.buffering = c.g_list_delete_link(s.buffering, l);
            removed = true;
            break;
        }
    }
    const post = removed and s.buffering == null;
    bufUnlock(s);
    if (post) _ = c.gst_element_post_message(elem(s), c.gst_message_new_buffering(cm.obj(s), 100));
    c.g_mutex_unlock(&s.post_lock);
}

fn demuxerInfoFor(s: *Self, child: ?*c.GstObject) ?*Info {
    var res: ?*Info = null;
    var p: ?*c.GstObject = @ptrCast(@alignCast(c.gst_object_ref(child)));
    while (true) {
        var l = s.infos;
        while (l != null) : (l = l.*.next) {
            const info: *Info = @ptrCast(@alignCast(l.*.data));
            if (info.demuxer != null and p == cm.obj(info.demuxer)) {
                res = info;
                break;
            }
        }
        const next = c.gst_object_get_parent(p);
        c.gst_object_unref(p);
        p = next;
        if (p == null or p == cm.obj(s)) break;
    }
    if (p) |x| c.gst_object_unref(x);
    return res;
}

fn compatible(streams: [*c]c.GList, stream: ?*c.GstStream) ?*c.GstStream {
    const t = c.gst_stream_get_stream_type(stream);
    var l = streams;
    while (l != null) : (l = l.*.next) {
        const x: ?*c.GstStream = @ptrCast(@alignCast(l.*.data));
        if (c.gst_stream_get_stream_type(x) == t) return x;
    }
    return null;
}

fn parsebinCollection(info: *Info, col: ?*c.GstStreamCollection) void {
    var streams: [*c]c.GList = null;
    const n = c.gst_stream_collection_get_size(col);
    var i: c.guint = 0;
    while (i < n) : (i += 1) streams = c.g_list_append(streams, c.gst_stream_collection_get_stream(col, i));
    var unused_streams = c.g_list_copy(streams);
    var unused_slots: [*c]c.GList = null;
    var it = slotsOf(info);
    while (it.next()) |x| {
        if (x.stream == null) continue;
        if (!utils.streamInList(streams, x.stream)) {
            unused_slots = c.g_list_append(unused_slots, x);
            continue;
        }
        var l = unused_streams;
        while (l != null) : (l = l.*.next) {
            const st: *c.GstStream = @ptrCast(@alignCast(l.*.data));
            if (c.g_strcmp0(x.stream.?.stream_id, st.stream_id) == 0) {
                _ = c.gst_object_replace(@ptrCast(&x.pending_stream), cm.obj(st));
                unused_streams = c.g_list_remove(unused_streams, st);
                break;
            }
        }
    }
    var l = unused_slots;
    while (l != null) : (l = l.*.next) {
        const x: *Slot = @ptrCast(@alignCast(l.*.data));
        if (compatible(unused_streams, x.stream)) |r| {
            _ = c.gst_object_replace(@ptrCast(&x.pending_stream), cm.obj(r));
            unused_streams = c.g_list_remove(unused_streams, r);
        }
    }
    c.g_list_free(unused_slots);
    c.g_list_free(streams);
    c.g_list_free(unused_streams);
    _ = c.gst_object_replace(@ptrCast(&info.collection), cm.obj(col));
}

fn aggregate(s: *Self) ?*c.GstStreamCollection {
    var res: ?*c.GstStreamCollection = null;
    var merge = false;
    var l = s.infos;
    while (l != null) : (l = l.*.next) {
        const info: *Info = @ptrCast(@alignCast(l.*.data));
        if (res != null and info.collection != null and info.collection != res) {
            merge = true;
            break;
        }
        if (info.collection != null) res = info.collection;
    }
    if (merge) {
        res = c.gst_stream_collection_new("urisourcebin");
        var streams: [*c]c.GList = null;
        l = s.infos;
        while (l != null) : (l = l.*.next) {
            const info: *Info = @ptrCast(@alignCast(l.*.data));
            const col = info.collection orelse continue;
            var i: c.guint = 0;
            while (i < c.gst_stream_collection_get_size(col)) : (i += 1) {
                const st = c.gst_stream_collection_get_stream(col, i);
                if (!utils.streamInList(streams, st)) streams = c.g_list_append(streams, st);
            }
        }
        l = streams;
        while (l != null) : (l = l.*.next) _ = c.gst_stream_collection_add_stream(res, @ptrCast(@alignCast(c.gst_object_ref(l.*.data))));
        c.g_list_free(streams);
    }
    _ = c.gst_object_replace(@ptrCast(&s.collection), cm.obj(res));
    return if (res) |x| @ptrCast(@alignCast(c.gst_object_ref(x))) else null;
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    var msg = msg_in;
    switch (msg.*.type) {
        c.GST_MESSAGE_ELEMENT => {
            if (c.gst_message_has_name(msg, "redirect") != 0) msg = redirect(s, msg);
        },
        c.GST_MESSAGE_STREAM_COLLECTION => {
            lock(s);
            if (demuxerInfoFor(s, msg.*.src)) |info| {
                info.streams_aware = true;
                if (info.is_parsebin) {
                    var col: ?*c.GstStreamCollection = null;
                    c.gst_message_parse_stream_collection(msg, &col);
                    if (col) |x| {
                        parsebinCollection(info, x);
                        const agg = aggregate(s);
                        if (agg != x) {
                            c.gst_message_unref(msg);
                            msg = c.gst_message_new_stream_collection(cm.obj(s), agg);
                        }
                        if (agg) |a| c.gst_object_unref(a);
                        c.gst_object_unref(x);
                    }
                }
            } else if (msg.*.src != cm.obj(s.source)) {
                c.gst_message_unref(msg);
                msg = null;
            }
            unlock(s);
        },
        c.GST_MESSAGE_BUFFERING => {
            handleBuffering(s, msg);
            msg = null;
        },
        c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
            if (@atomicLoad(c.gint, &s.flushing, .seq_cst) != 0) {
                c.gst_message_unref(msg);
                msg = null;
            }
        },
        else => {},
    }
    if (msg != null) parent_class.?.handle_message.?(b, msg);
}

const Fold = struct {
    query: ?*c.GstQuery,
    min: i64 = 0,
    max: i64 = -1,
    seekable: bool = true,
    live: bool = false,
    ok: bool = false,
};

fn foldPad(t: c.GstQueryType, pad: ?*c.GstPad, f: *Fold) bool {
    const q = f.query;
    switch (t) {
        c.GST_QUERY_DURATION, c.GST_QUERY_POSITION => {
            if (c.gst_pad_query(pad, q) != 0) {
                f.ok = true;
                var v: i64 = 0;
                if (t == c.GST_QUERY_DURATION) c.gst_query_parse_duration(q, null, &v) else c.gst_query_parse_position(q, null, &v);
                if (v > f.max) f.max = v;
            }
        },
        c.GST_QUERY_LATENCY => {
            if (c.gst_pad_query(pad, q) != 0) {
                var live: c.gboolean = 0;
                var mn: u64 = 0;
                var mx: u64 = 0;
                c.gst_query_parse_latency(q, &live, &mn, &mx);
                if (live != 0) {
                    if (@as(i64, @bitCast(mn)) > f.min) f.min = @bitCast(mn);
                    if (f.max == -1) {
                        f.max = @bitCast(mx);
                    } else if (@as(i64, @bitCast(mx)) < f.max) f.max = @bitCast(mx);
                    f.live = true;
                }
            } else f.ok = false;
        },
        c.GST_QUERY_SEEKING => {
            if (c.gst_pad_query(pad, q) != 0) {
                f.ok = true;
                var seekable: c.gboolean = 0;
                c.gst_query_parse_seeking(q, null, &seekable, null, null);
                if (f.seekable) f.seekable = seekable != 0;
            }
        },
        else => {
            if (c.gst_pad_query(pad, q) != 0) {
                f.ok = true;
                return false;
            }
        },
    }
    return true;
}

fn foldDone(t: c.GstQueryType, f: *Fold) void {
    const q = f.query;
    var format: c.GstFormat = 0;
    switch (t) {
        c.GST_QUERY_DURATION => {
            c.gst_query_parse_duration(q, &format, null);
            c.gst_query_set_duration(q, format, f.max);
        },
        c.GST_QUERY_POSITION => {
            c.gst_query_parse_position(q, &format, null);
            c.gst_query_set_position(q, format, f.max);
        },
        c.GST_QUERY_LATENCY => c.gst_query_set_latency(q, @intFromBool(f.live), @bitCast(f.min), @bitCast(f.max)),
        c.GST_QUERY_SEEKING => {
            c.gst_query_parse_seeking(q, &format, null, null, null);
            c.gst_query_set_seeking(q, format, @intFromBool(f.seekable), 0, -1);
        },
        else => {},
    }
}

fn query(e: [*c]c.GstElement, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const s = me(e);
    const t = cm.queryType(q);
    switch (t) {
        c.GST_QUERY_SELECTABLE => {
            if (s.is_adaptive != 0) {
                if (s.infos != null) {
                    const info: *Info = @ptrCast(@alignCast(s.infos.*.data));
                    if (info.demuxer) |d| return c.gst_element_query(d, q);
                }
                return 0;
            }
            return c.gst_element_query(s.source, q);
        },
        else => {},
    }
    const folding = t == c.GST_QUERY_DURATION or t == c.GST_QUERY_POSITION or t == c.GST_QUERY_LATENCY or t == c.GST_QUERY_SEEKING;
    const default_ok = t == c.GST_QUERY_LATENCY;
    var f = Fold{ .query = q, .ok = default_ok };
    const it = c.gst_element_iterate_src_pads(e);
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&item)));
                const more = foldPad(t, pad, &f);
                _ = c.g_value_reset(&item);
                if (!more) return 1;
            },
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                f = .{ .query = q, .ok = default_ok };
            },
            c.GST_ITERATOR_DONE => {
                if (folding and f.ok) foldDone(t, &f);
                return @intFromBool(f.ok);
            },
            else => return 0,
        }
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            @atomicStore(c.gint, &s.flushing, 0, .seq_cst);
            lock(s);
            s.activated = 0;
            unlock(s);
            if (!setupSource(s)) {
                removeSource(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            @atomicStore(c.gint, &s.flushing, 1, .seq_cst);
            lock(s);
            c.g_cond_broadcast(&s.activation);
            unlock(s);
        },
        else => {},
    }
    const ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) removeSource(s);
        return c.GST_STATE_CHANGE_FAILURE;
    }
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lock(s);
            s.activated = 1;
            c.g_cond_broadcast(&s.activation);
            unlock(s);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            removeSource(s);
            c.g_list_free_full(s.buffering, @ptrCast(&c.gst_mini_object_unref));
            s.buffering = null;
            s.last_pct = -1;
        },
        else => {},
    }
    return ret;
}

fn updateSpeed(s: *Self) void {
    if (s.is_adaptive == 0) return;
    cm.lock(s);
    const speed = s.speed / 1000;
    cm.unlock(s);
    lock(s);
    defer unlock(s);
    var l = s.infos;
    while (l != null) : (l = l.*.next) {
        const info: *Info = @ptrCast(@alignCast(l.*.data));
        const d = info.demuxer orelse continue;
        if (hasProp(d, "connection-speed") != null) c.g_object_set(gobj(d), "connection-speed", speed, N);
    }
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_URI => {
            cm.lock(s);
            c.g_free(s.uri);
            s.uri = c.g_value_dup_string(v);
            cm.unlock(s);
        },
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            s.speed = c.g_value_get_uint64(v) *% 1000;
            cm.unlock(s);
            updateSpeed(s);
        },
        PROP_BUFFER_SIZE => {
            s.buffer_size = c.g_value_get_int(v);
            updateQueues(s);
        },
        PROP_BUFFER_DURATION => {
            s.buffer_duration = c.g_value_get_int64(v);
            updateQueues(s);
        },
        PROP_DOWNLOAD => s.download = c.g_value_get_boolean(v),
        PROP_DOWNLOAD_DIR => {
            c.g_free(s.download_dir);
            s.download_dir = c.g_value_dup_string(v);
        },
        PROP_USE_BUFFERING => s.use_buffering = c.g_value_get_boolean(v),
        PROP_RING_BUFFER_MAX_SIZE => s.ring_max = c.g_value_get_uint64(v),
        PROP_LOW_WATERMARK => {
            s.low = c.g_value_get_double(v);
            updateQueues(s);
        },
        PROP_HIGH_WATERMARK => {
            s.high = c.g_value_get_double(v);
            updateQueues(s);
        },
        PROP_PARSE_STREAMS => s.parse_streams = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 660),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_URI => {
            cm.lock(s);
            c.g_value_set_string(v, s.uri);
            cm.unlock(s);
        },
        PROP_SOURCE => {
            cm.lock(s);
            c.g_value_set_object(v, s.source);
            cm.unlock(s);
        },
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            c.g_value_set_uint64(v, s.speed / 1000);
            cm.unlock(s);
        },
        PROP_BUFFER_SIZE => {
            cm.lock(s);
            c.g_value_set_int(v, s.buffer_size);
            cm.unlock(s);
        },
        PROP_BUFFER_DURATION => {
            cm.lock(s);
            c.g_value_set_int64(v, s.buffer_duration);
            cm.unlock(s);
        },
        PROP_DOWNLOAD => c.g_value_set_boolean(v, s.download),
        PROP_DOWNLOAD_DIR => c.g_value_set_string(v, s.download_dir),
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, s.use_buffering),
        PROP_RING_BUFFER_MAX_SIZE => c.g_value_set_uint64(v, s.ring_max),
        PROP_LOW_WATERMARK => c.g_value_set_double(v, s.low),
        PROP_HIGH_WATERMARK => c.g_value_set_double(v, s.high),
        PROP_STATISTICS => c.g_value_take_boxed(v, statistics(s)),
        PROP_PARSE_STREAMS => c.g_value_set_boolean(v, s.parse_streams),
        else => cm.warnInvalid(FILE, o, id, spec, 722),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_mutex_clear(&s.lock);
    c.g_mutex_clear(&s.buffering_lock);
    c.g_mutex_clear(&s.post_lock);
    c.g_free(s.uri);
    c.g_free(s.download_dir);
    _ = c.gst_object_replace(@ptrCast(&s.collection), null);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, PROP_URI, c.g_param_spec_string("uri", "URI", "URI to decode", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SOURCE, c.g_param_spec_object("source", "Source", "Source object used", c.gst_element_get_type(), ro));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_SIZE, c.g_param_spec_int("buffer-size", "Buffer size (bytes)", "Buffer size when buffering streams (-1 default value)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_DURATION, c.g_param_spec_int64("buffer-duration", "Buffer duration (ns)", "Buffer duration when buffering streams (-1 default value)", -1, std.math.maxInt(i64), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_DOWNLOAD, c.g_param_spec_boolean("download", "Download", "Attempt download buffering when buffering network streams", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_DOWNLOAD_DIR, c.g_param_spec_string("download-dir", "Download Directory", "The directory where buffers are downloaded to, if 'download' is enabled. If not set (default), the XDG cache directory is used.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_BUFFERING, c.g_param_spec_boolean("use-buffering", "Use Buffering", "Perform buffering on demuxed/parsed media", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_RING_BUFFER_MAX_SIZE, c.g_param_spec_uint64("ring-buffer-max-size", "Max. ring buffer size (bytes)", "Max. amount of data in the ring buffer (bytes, 0 = ring buffer disabled)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_LOW_WATERMARK, c.g_param_spec_double("low-watermark", "Low watermark", "Low threshold for buffering to start. Only used if use-buffering is True", 0.0, 1.0, 0.01, cm.RW));
    c.g_object_class_install_property(oc, PROP_HIGH_WATERMARK, c.g_param_spec_double("high-watermark", "High watermark", "High threshold for buffering to finish. Only used if use-buffering is True", 0.0, 1.0, 0.60, cm.RW));
    c.g_object_class_install_property(oc, PROP_STATISTICS, c.g_param_spec_boxed("statistics", "Queue Statistics", "A set of statistics over all the queue-like elements contained in this element", c.gst_structure_get_type(), ro));
    c.g_object_class_install_property(oc, PROP_PARSE_STREAMS, c.g_param_spec_boolean("parse-streams", "Parse Streams", "Extract the elementary streams of non-raw sources", 0, cm.RW));
    const t = cm.typeOfClass(k);
    signals[SIG_DRAINED] = c.g_signal_new("drained", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "drained"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[SIG_ABOUT_TO_FINISH] = c.g_signal_new("about-to-finish", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "about_to_finish"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[SIG_SOURCE_SETUP] = c.g_signal_new("source-setup", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, c.gst_element_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    c.gst_element_class_set_static_metadata(ec, "URI reader", "Generic/Bin/Source", "Download and buffer a URI as needed", "Jan Schmidt <jan@centricular.com>");
    ec.query = query;
    ec.change_state = changeState;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    _ = c._gst_debug_category_new("urisourcebin", 0, "URI source element");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    c.g_mutex_init(&s.lock);
    c.g_mutex_init(&s.buffering_lock);
    c.g_mutex_init(&s.post_lock);
    c.g_cond_init(&s.activation);
    s.uri = null;
    s.speed = 0;
    s.buffer_duration = -1;
    s.buffer_size = -1;
    s.download = 0;
    s.use_buffering = 1;
    s.ring_max = 0;
    s.last_pct = -1;
    s.low = 0.01;
    s.high = 0.60;
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_SOURCE | c.GST_BIN_FLAG_STREAMS_AWARE;
    c.gst_bin_set_suppressed_flags(binOf(s), c.GST_ELEMENT_FLAG_SOURCE | c.GST_ELEMENT_FLAG_SINK);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstURISourceBin", Class, Self, classInit, init);
        }
    }.f);
}
