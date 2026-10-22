const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const dt = @import("dtypes.zig");
const desc = @import("desc.zig");
const missing = @import("missing.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Disco = c.GstDiscoverer;
const DiscoClass = c.GstDiscovererClass;
const ODisco = ?*c.GstDiscoverer;
const OInfo = ?*c.GstDiscovererInfo;
const Caps = c.GstCaps;
const VNONE = @as(?*anyopaque, null);
const PATH = "../gst-libs/gst/pbutils/gstdiscoverer.c";
const SEC: u64 = c.GST_SECOND;

const PStream = struct {
    dc: *Disco,
    pad: ?*c.GstPad,
    queue: ?*c.GstElement = null,
    sink: ?*c.GstElement = null,
    tags: ?*c.GstTagList = null,
    toc: ?*c.GstToc = null,
    stream_id: [*c]u8 = null,
    probe_id: c.gulong = 0,
};

const Priv = struct {
    is_async: bool,
    timeout: u64,
    pending: [*c]c.GList,
    lock: c.GMutex,
    cleanup: bool,
    processing: bool,
    running: bool,
    current: ?*dt.Info,
    stream_count: c.gint,
    current_error: [*c]c.GError,
    topology: ?*c.GstStructure,
    cachefile: [*c]u8,
    from_cache: bool,
    all_tags: ?*c.GstTagList,
    global_tags: ?*c.GstTagList,
    streams: [*c]c.GList,
    pending_subs: c.guint,
    no_more_pads: bool,
    target_state: c.GstState,
    current_state: c.GstState,
    pipeline: ?*c.GstElement,
    uridecodebin: ?*c.GstElement,
    bus: ?*c.GstBus,
    ctx: ?*c.GMainContext,
    bus_source: ?*c.GSource,
    timeout_source: ?*c.GSource,
    seeking_query: [*c]c.GstQuery,
    pad_added_id: c.gulong,
    pad_remove_id: c.gulong,
    no_more_pads_id: c.gulong,
    source_chg_id: c.gulong,
    bus_cb_id: c.gulong,
    use_cache: bool,
};

const S_FINISHED = 0;
const S_STARTING = 1;
const S_DISCOVERED = 2;
const S_SOURCE_SETUP = 3;
const S_LOAD = 4;

var signals = [_]c.guint{0} ** 5;
var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn pv(dc: anytype) *Priv {
    return @ptrCast(@alignCast(@as(*Disco, @ptrCast(@alignCast(dc))).priv));
}

fn lock(dc: anytype) void {
    c.g_mutex_lock(&pv(dc).lock);
}

fn unlock(dc: anytype) void {
    c.g_mutex_unlock(&pv(dc).lock);
}

fn isDisco(p: anytype) bool {
    return gtype.instanceOf(p, gst_discoverer_get_type());
}

fn accumulate(_: [*c]c.GSignalInvocationHint, accu: [*c]c.GValue, ret: [*c]const c.GValue, _: c.gpointer) callconv(.c) c.gboolean {
    const i = c.g_value_get_object(ret);
    c.g_value_set_object(accu, i);
    return @intFromBool(i == null);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&pv(o).lock);
    parent.?.finalize.?(o);
}

fn reset(dc: anytype) void {
    const p = pv(dc);
    if (p.pending != null) {
        c.g_list_foreach(p.pending, @ptrCast(&c.g_free), null);
        c.g_list_free(p.pending);
        p.pending = null;
    }
    if (p.pipeline != null) _ = c.gst_element_set_state(p.pipeline, c.GST_STATE_NULL);
}

fn disconnect(o: anytype, id: *c.gulong) void {
    if (id.* != 0 and c.g_signal_handler_is_connected(o, id.*) != 0) c.g_signal_handler_disconnect(o, id.*);
    id.* = 0;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const p = pv(o);
    reset(o);
    if (p.pipeline != null) {
        disconnect(p.uridecodebin, &p.pad_added_id);
        disconnect(p.uridecodebin, &p.pad_remove_id);
        disconnect(p.uridecodebin, &p.no_more_pads_id);
        disconnect(p.uridecodebin, &p.source_chg_id);
        disconnect(p.bus, &p.bus_cb_id);
        c.gst_object_unref(p.pipeline);
        if (p.bus != null) c.gst_object_unref(p.bus);
        p.pipeline = null;
        p.uridecodebin = null;
        p.bus = null;
    }
    gst_discoverer_stop(@ptrCast(o));
    if (p.seeking_query != null) {
        c.gst_mini_object_unref(@ptrCast(p.seeking_query));
        p.seeking_query = null;
    }
    parent.?.dispose.?(o);
}

fn setTimeout(dc: anytype, t: u64) void {
    if (!check.that(t != el.NONE, "gst_discoverer_set_timeout", "GST_CLOCK_TIME_IS_VALID (timeout)")) return;
    lock(dc);
    pv(dc).timeout = t;
    unlock(dc);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => setTimeout(o, c.g_value_get_uint64(v)),
        2 => {
            lock(o);
            pv(o).use_cache = c.g_value_get_boolean(v) != 0;
            unlock(o);
        },
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 507),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => {
            lock(o);
            c.g_value_set_uint64(v, pv(o).timeout);
            unlock(o);
        },
        2 => {
            lock(o);
            c.g_value_set_boolean(v, @intFromBool(pv(o).use_cache));
            unlock(o);
        },
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 530),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const dk: *DiscoClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    dk.load_serialize_info = @ptrCast(&loadSerialized);
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_uint64("timeout", "timeout", "Timeout", SEC, 3600 * SEC, 15 * SEC, flags));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_boolean("use-cache", "use cache", "Use cache", 0, flags));
    const t = gtype.typeOf(@as(*c.GTypeInstance, @ptrCast(@alignCast(k))));
    _ = t;
    const kt = @as(*c.GTypeClass, @ptrCast(@alignCast(k))).g_type;
    signals[S_FINISHED] = c.g_signal_new("finished", kt, c.G_SIGNAL_RUN_LAST, @offsetOf(DiscoClass, "finished"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[S_STARTING] = c.g_signal_new("starting", kt, c.G_SIGNAL_RUN_LAST, @offsetOf(DiscoClass, "starting"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[S_DISCOVERED] = c.g_signal_new("discovered", kt, c.G_SIGNAL_RUN_LAST, @offsetOf(DiscoClass, "discovered"), null, null, null, c.G_TYPE_NONE, 2, dt.gst_discoverer_info_get_type(), c.g_error_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    signals[S_SOURCE_SETUP] = c.g_signal_new("source-setup", kt, c.G_SIGNAL_RUN_LAST, @offsetOf(DiscoClass, "source_setup"), null, null, null, c.G_TYPE_NONE, 1, c.gst_element_get_type());
    signals[S_LOAD] = c.g_signal_new("load-serialized-info", kt, c.G_SIGNAL_RUN_LAST, @offsetOf(DiscoClass, "load_serialize_info"), accumulate, null, null, dt.gst_discoverer_info_get_type(), 1, c.G_TYPE_STRING);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const dc: *Disco = @ptrCast(@alignCast(inst));
    dc.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    const p = pv(dc);
    p.* = std.mem.zeroes(Priv);
    p.timeout = 15 * SEC;
    c.g_mutex_init(&p.lock);
    p.current_state = c.GST_STATE_NULL;
    p.target_state = c.GST_STATE_NULL;
    p.pipeline = c.gst_pipeline_new("Discoverer");
    p.uridecodebin = c.gst_element_factory_make("uridecodebin", "discoverer-uri");
    if (p.uridecodebin == null) return;
    c.g_object_set(p.uridecodebin, "post-stream-topology", @as(c.gboolean, 1), VNONE);
    _ = c.gst_bin_add(@ptrCast(p.pipeline), p.uridecodebin);
    p.pad_added_id = c.g_signal_connect_object(p.uridecodebin, "pad-added", @ptrCast(&padAdded), dc, 0);
    p.pad_remove_id = c.g_signal_connect_object(p.uridecodebin, "pad-removed", @ptrCast(&padRemoved), dc, 0);
    p.no_more_pads_id = c.g_signal_connect_object(p.uridecodebin, "no-more-pads", @ptrCast(&noMorePads), dc, 0);
    p.source_chg_id = c.g_signal_connect_object(p.uridecodebin, "notify::source", @ptrCast(&sourceChanged), dc, 0);
    p.bus = c.gst_pipeline_get_bus(@ptrCast(p.pipeline));
    p.bus_cb_id = c.g_signal_connect_object(p.bus, "message", @ptrCast(&busCb), dc, 0);
    p.seeking_query = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
}

pub export fn gst_discoverer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.g_object_get_type, "GstDiscoverer", DiscoClass, Disco, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("discoverer", 0, "Discoverer");
            return t;
        }
    }.f);
}

fn eventProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, ps: *PStream) callconv(.c) c.GstPadProbeReturn {
    const ev: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
    switch (ev[0].type) {
        c.GST_EVENT_TOC => {
            var toc: ?*c.GstToc = null;
            c.gst_event_parse_toc(ev, &toc, null);
            lock(ps.dc);
            ps.toc = toc;
            unlock(ps.dc);
        },
        c.GST_EVENT_STREAM_START => {
            var sid: [*c]const u8 = null;
            c.gst_event_parse_stream_start(ev, &sid);
            c.g_free(ps.stream_id);
            ps.stream_id = if (sid != null) c.g_strdup(sid) else null;
        },
        else => {},
    }
    return c.GST_PAD_PROBE_OK;
}

var subtitle_caps = c.GstStaticCaps{ .caps = null, .string = "application/x-ssa; application/x-ass; application/x-kate", ._gst_reserved = .{ null, null, null, null } };

fn isSubtitleCaps(caps: [*c]const Caps) bool {
    const s = c.gst_caps_get_structure(caps, 0);
    if (s == null) return false;
    const name = c.gst_structure_get_name(s);
    for ([_][*:0]const u8{ "text/", "subpicture/", "subtitle/", "closedcaption/", "application/x-subtitle" }) |pfx| {
        if (c.g_str_has_prefix(name, pfx) != 0) return true;
    }
    const sc = c.gst_static_caps_get(&subtitle_caps);
    const r = c.gst_caps_can_intersect(caps, sc) != 0;
    c.gst_mini_object_unref(@ptrCast(sc));
    return r;
}

fn subtitleData(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, dc: *Disco) callconv(.c) c.GstPadProbeReturn {
    const m: [*c]c.GstMiniObject = @ptrCast(@alignCast(info[0].data));
    const is_buf = m != null and m[0].type == c.gst_buffer_get_type();
    var is_ev = false;
    if (m != null and m[0].type == c.gst_event_get_type()) {
        const t = @as([*c]c.GstEvent, @ptrCast(m))[0].type;
        is_ev = t == c.GST_EVENT_GAP or t == c.GST_EVENT_EOS;
    }
    if (!is_buf and !is_ev) return c.GST_PAD_PROBE_OK;
    lock(dc);
    pv(dc).pending_subs -%= 1;
    _ = c.gst_element_post_message(pv(dc).pipeline, c.gst_message_new_application(null, c.gst_structure_new_empty("DiscovererDone")));
    unlock(dc);
    return c.GST_PAD_PROBE_REMOVE;
}

fn sourceChanged(ud: ?*c.GstElement, pspec: [*c]c.GParamSpec, dc: *Disco) callconv(.c) void {
    var src: ?*c.GstElement = null;
    c.g_object_get(ud, pspec[0].name, &src, VNONE);
    c.g_signal_emit(dc, signals[S_SOURCE_SETUP], 0, src);
    c.gst_object_unref(src);
}

fn padAdded(_: ?*c.GstElement, pad: ?*c.GstPad, dc: *Disco) callconv(.c) void {
    const p = pv(dc);
    lock(dc);
    defer unlock(dc);
    if (p.cleanup or p.current_error != null) return;
    const ps: *PStream = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(PStream))));
    ps.* = .{ .dc = dc, .pad = pad };
    const padname = c.gst_object_get_name(@ptrCast(@alignCast(pad)));
    var tmp = c.g_strdup_printf("discoverer-queue-%s", padname);
    ps.queue = c.gst_element_factory_make("queue", tmp);
    c.g_free(tmp);
    tmp = c.g_strdup_printf("discoverer-sink-%s", padname);
    ps.sink = c.gst_element_factory_make("fakesink", tmp);
    c.g_free(tmp);
    c.g_free(padname);
    var sinkpad: ?*c.GstPad = null;
    blk: {
        if (ps.queue == null or ps.sink == null) break :blk;
        c.g_object_set(ps.sink, "silent", @as(c.gboolean, 1), VNONE);
        c.g_object_set(ps.queue, "max-size-buffers", @as(c.guint, 1), "silent", @as(c.gboolean, 1), VNONE);
        sinkpad = c.gst_element_get_static_pad(ps.queue, "sink");
        if (sinkpad == null) break :blk;
        var caps = c.gst_pad_get_current_caps(pad);
        if (caps == null) caps = c.gst_pad_query_caps(pad, null);
        if (caps != null and c.gst_caps_is_empty(caps) == 0 and c.gst_caps_is_any(caps) == 0 and isSubtitleCaps(caps)) {
            ps.probe_id = c.gst_pad_add_probe(sinkpad, c.GST_PAD_PROBE_TYPE_DATA_DOWNSTREAM, @ptrCast(&subtitleData), dc, null);
            c.g_object_set(ps.sink, "async", @as(c.gboolean, 0), VNONE);
            p.pending_subs += 1;
        }
        if (caps != null) c.gst_mini_object_unref(@ptrCast(caps));
        c.gst_bin_add_many(@ptrCast(p.pipeline), ps.queue, ps.sink, VNONE);
        if (c.gst_element_link_pads_full(ps.queue, "src", ps.sink, "sink", c.GST_PAD_LINK_CHECK_NOTHING) == 0) break :blk;
        if (c.gst_element_sync_state_with_parent(ps.sink) == 0) break :blk;
        if (c.gst_element_sync_state_with_parent(ps.queue) == 0) break :blk;
        if (c.gst_pad_link_full(pad, sinkpad, c.GST_PAD_LINK_CHECK_NOTHING) != c.GST_PAD_LINK_OK) break :blk;
        c.gst_object_unref(sinkpad);
        _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, @ptrCast(&eventProbe), ps, null);
        p.streams = c.g_list_append(p.streams, ps);
        return;
    }
    if (sinkpad != null) c.gst_object_unref(sinkpad);
    if (ps.queue != null) c.gst_object_unref(ps.queue);
    if (ps.sink != null) c.gst_object_unref(ps.sink);
    c.g_free(ps);
}

fn noMorePads(_: ?*c.GstElement, dc: *Disco) callconv(.c) void {
    const msg = c.gst_message_new_application(null, c.gst_structure_new_empty("DiscovererDone"));
    lock(dc);
    pv(dc).no_more_pads = true;
    _ = c.gst_element_post_message(pv(dc).pipeline, msg);
    unlock(dc);
}

fn padRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, dc: *Disco) callconv(.c) void {
    const p = pv(dc);
    lock(dc);
    var l = p.streams;
    while (l != null) : (l = l[0].next) {
        if (@as(*PStream, @ptrCast(@alignCast(l[0].data))).pad == pad) break;
    }
    if (l == null) {
        unlock(dc);
        return;
    }
    const ps: *PStream = @ptrCast(@alignCast(l[0].data));
    if (ps.probe_id != 0) c.gst_pad_remove_probe(pad, ps.probe_id);
    p.streams = c.g_list_delete_link(p.streams, l);
    _ = c.gst_element_set_state(ps.sink, c.GST_STATE_NULL);
    _ = c.gst_element_set_state(ps.queue, c.GST_STATE_NULL);
    c.gst_element_unlink(ps.queue, ps.sink);
    const sinkpad = c.gst_element_get_static_pad(ps.queue, "sink");
    _ = c.gst_pad_unlink(pad, sinkpad);
    c.gst_object_unref(sinkpad);
    c.gst_bin_remove_many(@ptrCast(p.pipeline), ps.sink, ps.queue, VNONE);
    unlock(dc);
    if (ps.tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    if (ps.toc) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
    c.g_free(ps.stream_id);
    c.g_free(ps);
}

fn streamInformation(ps: *PStream, idx: c.guint) ?*c.GstStructure {
    const name = c.g_strdup_printf("stream-%02d", idx);
    const st = c.gst_structure_new_empty(name);
    c.g_free(name);
    var caps = c.gst_pad_get_current_caps(ps.pad);
    if (caps == null) caps = c.gst_pad_query_caps(ps.pad, null);
    if (caps != null) {
        c.gst_structure_set_static_str(st, "caps", c.gst_caps_get_type(), caps, VNONE);
        c.gst_mini_object_unref(@ptrCast(caps));
    }
    if (ps.tags) |t| c.gst_structure_set_static_str(st, "tags", c.gst_tag_list_get_type(), t, VNONE);
    if (ps.toc) |t| c.gst_structure_set_static_str(st, "toc", c.gst_toc_get_type(), t, VNONE);
    if (ps.stream_id != null) c.gst_structure_set_static_str(st, "stream-id", c.G_TYPE_STRING, ps.stream_id, VNONE);
    return st;
}

fn mergeTags(list: *?*c.GstTagList, new: ?*c.GstTagList) void {
    if (new == null) return;
    if (list.* == null) {
        list.* = new;
        return;
    }
    c.gst_tag_list_insert(list.*, new, c.GST_TAG_MERGE_REPLACE);
    c.gst_mini_object_unref(@ptrCast(@alignCast(new)));
}

fn common(info: *dt.Stream, st: ?*const c.GstStructure) void {
    if (c.gst_structure_has_field(st, "toc") != 0) _ = c.gst_structure_get(st, "toc", c.gst_toc_get_type(), &info.toc, VNONE);
    if (c.gst_structure_has_field(st, "stream-id") != 0) _ = c.gst_structure_get(st, "stream-id", c.G_TYPE_STRING, &info.stream_id, VNONE);
}

fn makeInfo(par: ?*dt.Stream, t: c.GType, caps: [*c]Caps) *dt.Stream {
    if (par) |p| return dt.stream(c.g_object_ref(p));
    const i = dt.stream(dt.new(t));
    if (caps != null) i.caps = c.gst_caps_ref(caps);
    return i;
}

fn bitrates(st: ?*const c.GstStructure, info: *dt.Stream, br: *c.guint, maxbr: *c.guint) void {
    if (c.gst_structure_has_field(st, "tags") == 0) return;
    var tags: ?*c.GstTagList = null;
    _ = c.gst_structure_get(st, "tags", c.gst_tag_list_get_type(), &tags, VNONE);
    var u: c.guint = 0;
    if (c.gst_tag_list_get_uint(tags, c.GST_TAG_BITRATE, &u) != 0 or c.gst_tag_list_get_uint(tags, c.GST_TAG_NOMINAL_BITRATE, &u) != 0) br.* = u;
    if (c.gst_tag_list_get_uint(tags, c.GST_TAG_MAXIMUM_BITRATE, &u) != 0) maxbr.* = u;
    mergeTags(&info.tags, tags);
}

fn languageFromTags(info: *dt.Stream, lang: *[*c]u8) void {
    if (lang.* != null or info.tags == null) return;
    var l: [*c]u8 = null;
    if (c.gst_tag_list_get_string(info.tags, c.GST_TAG_LANGUAGE_CODE, &l) != 0) lang.* = l;
}

fn collect(st: ?*const c.GstStructure, par: ?*dt.Stream) *dt.Stream {
    if (st == null or (c.gst_structure_has_field(st, "caps") == 0 and c.gst_structure_has_field(st, "element-srcpad") == 0)) return makeInfo(par, dt.gst_discoverer_stream_info_get_type(), null);
    var caps: [*c]Caps = null;
    var srcpad: ?*c.GstPad = null;
    if (c.gst_structure_get(st, "element-srcpad", c.gst_pad_get_type(), &srcpad, VNONE) != 0) {
        caps = c.gst_pad_get_current_caps(srcpad);
        c.gst_object_unref(srcpad);
    }
    if (caps == null) _ = c.gst_structure_get(st, "caps", c.gst_caps_get_type(), &caps, VNONE);
    if (caps == null or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) {
        if (caps != null) c.gst_mini_object_unref(@ptrCast(caps));
        return makeInfo(par, dt.gst_discoverer_stream_info_get_type(), null);
    }
    defer c.gst_mini_object_unref(@ptrCast(caps));
    const cs = c.gst_caps_get_structure(caps, 0);
    const name = c.gst_structure_get_name(cs);
    var tmp: c.gint = 0;
    var tmp2: c.gint = 0;
    if (c.g_str_has_prefix(name, "audio/") != 0) {
        const s = makeInfo(par, dt.gst_discoverer_audio_info_get_type(), caps);
        const a: *dt.Audio = @ptrCast(s);
        if (c.gst_structure_get_int(cs, "rate", &tmp) != 0) a.sample_rate = @bitCast(tmp);
        if (c.gst_structure_get_int(cs, "channels", &tmp) != 0) a.channels = @bitCast(tmp);
        var mask: u64 = 0;
        if (c.gst_structure_get(cs, "channel-mask", c.gst_bitmask_get_type(), &mask, VNONE) != 0) {
            a.channel_mask = mask;
        } else if (a.channels != 0) a.channel_mask = c.gst_audio_channel_get_fallback_mask(@intCast(a.channels));
        const fs = c.gst_structure_get_string(cs, "format");
        if (fs != null) {
            const fi = c.gst_audio_format_get_info(c.gst_audio_format_from_string(fs));
            if (fi != null) a.depth = @bitCast(fi[0].depth);
        }
        bitrates(st, s, &a.bitrate, &a.max_bitrate);
        common(s, st);
        languageFromTags(s, &a.language);
        return s;
    }
    if (c.g_str_has_prefix(name, "video/") != 0 or c.g_str_has_prefix(name, "image/") != 0) {
        const s = makeInfo(par, dt.gst_discoverer_video_info_get_type(), caps);
        const v: *dt.Video = @ptrCast(s);
        if (c.gst_structure_get_int(cs, "width", &tmp) != 0) v.width = @bitCast(tmp);
        if (c.gst_structure_get_int(cs, "height", &tmp) != 0) v.height = @bitCast(tmp);
        if (c.gst_structure_get_fraction(cs, "framerate", &tmp, &tmp2) != 0) {
            v.framerate_num = @bitCast(tmp);
            v.framerate_denom = @bitCast(tmp2);
        } else {
            v.framerate_num = 0;
            v.framerate_denom = 1;
        }
        if (c.gst_structure_get_fraction(cs, "pixel-aspect-ratio", &tmp, &tmp2) != 0) {
            v.par_num = @bitCast(tmp);
            v.par_denom = @bitCast(tmp2);
        } else {
            v.par_num = 1;
            v.par_denom = 1;
        }
        const fs = c.gst_structure_get_string(cs, "format");
        if (fs != null) {
            const fi = c.gst_video_format_get_info(c.gst_video_format_from_string(fs));
            if (fi != null) v.depth = fi[0].bits * fi[0].n_components;
        }
        const im = c.gst_structure_get_string(cs, "interlace-mode");
        v.interlaced = @intFromBool(!(im == null or c.strcmp(im, "progressive") == 0));
        bitrates(st, s, &v.bitrate, &v.max_bitrate);
        common(s, st);
        return s;
    }
    if (isSubtitleCaps(caps)) {
        const s = makeInfo(par, dt.gst_discoverer_subtitle_info_get_type(), caps);
        const sub: *dt.Subtitle = @ptrCast(s);
        if (c.gst_structure_has_field(st, "tags") != 0) {
            var tags: ?*c.GstTagList = null;
            _ = c.gst_structure_get(st, "tags", c.gst_tag_list_get_type(), &tags, VNONE);
            const lang = c.gst_structure_get_string(cs, c.GST_TAG_LANGUAGE_CODE);
            if (lang != null) sub.language = c.g_strdup(lang);
            mergeTags(&s.tags, tags);
        }
        common(s, st);
        languageFromTags(s, &sub.language);
        return s;
    }
    const s = makeInfo(par, dt.gst_discoverer_stream_info_get_type(), caps);
    var tags: ?*c.GstTagList = null;
    if (c.gst_structure_get(st, "tags", c.gst_tag_list_get_type(), &tags, VNONE) != 0) mergeTags(&s.tags, tags);
    common(s, st);
    return s;
}

fn streamForNode(dc: *Disco, topology: ?*const c.GstStructure) ?*c.GstStructure {
    const p = pv(dc);
    if (p.streams == null) return null;
    if (c.gst_structure_has_field(topology, "pad") == 0) return null;
    var pad: ?*c.GstPad = null;
    _ = c.gst_structure_get(topology, "pad", c.gst_pad_get_type(), &pad, VNONE);
    defer c.gst_object_unref(pad);
    var l = p.streams;
    var i: c.guint = 0;
    while (l != null) : ({
        l = l[0].next;
        i += 1;
    }) {
        const ps: *PStream = @ptrCast(@alignCast(l[0].data));
        const target = c.gst_ghost_pad_get_target(@ptrCast(ps.pad));
        if (target == null) continue;
        c.gst_object_unref(target);
        if (target == pad) return streamInformation(ps, i);
    }
    return null;
}

fn sameStream(par: [*c]const Caps, child: [*c]const Caps) bool {
    if (par == child) return true;
    if (par == null or child == null) return false;
    const cp = desc.cleanCaps(par);
    defer c.gst_mini_object_unref(@ptrCast(cp));
    return c.gst_caps_can_intersect(cp, child) != 0;
}

fn rawStream(par: [*c]const Caps, child: [*c]const Caps) bool {
    if (par == child) return true;
    if (par == null or child == null) return false;
    const n1 = c.gst_structure_get_name(c.gst_caps_get_structure(par, 0));
    const n2 = c.gst_structure_get_name(c.gst_caps_get_structure(child, 0));
    if (c.g_str_has_prefix(n1, "audio/") != 0 and c.g_str_has_prefix(n2, "audio/x-raw") != 0) return true;
    if ((c.g_str_has_prefix(n1, "video/") != 0 or c.g_str_has_prefix(n1, "image/") != 0) and c.g_str_has_prefix(n2, "video/x-raw") != 0) return true;
    return isSubtitleCaps(par);
}

fn nodeCaps(st: ?*const c.GstStructure) [*c]Caps {
    var caps: [*c]Caps = null;
    var srcpad: ?*c.GstPad = null;
    if (c.gst_structure_get(st, "element-srcpad", c.gst_pad_get_type(), &srcpad, VNONE) != 0) {
        caps = c.gst_pad_get_current_caps(srcpad);
        c.gst_object_unref(srcpad);
    }
    if (caps == null) _ = c.gst_structure_get(st, "caps", c.gst_caps_get_type(), &caps, VNONE);
    return caps;
}

fn parseTopology(dc: *Disco, topology: ?*const c.GstStructure, par_in: ?*dt.Stream) ?*dt.Stream {
    const p = pv(dc);
    var par = par_in;
    const nval = c.gst_structure_get_value(topology, "next");
    if (nval == null or c.g_type_check_value_holds(nval, c.gst_structure_get_type()) != 0) {
        const st = streamForNode(dc, topology);
        var add = true;
        var res: *dt.Stream = undefined;
        if (st) |s| {
            res = collect(s, par);
            c.gst_structure_free(s);
        } else res = collect(topology, par);
        if (nval != null) {
            const next_st = c.gst_value_get_structure(nval);
            if (par == null) par = res;
            const caps = nodeCaps(next_st);
            if (caps != null) {
                if (sameStream(par.?.caps, caps)) {
                    _ = c.gst_mini_object_replace(@ptrCast(&par.?.caps), @ptrCast(caps));
                    _ = parseTopology(dc, next_st, par);
                    add = false;
                } else if (rawStream(par.?.caps, caps)) {
                    _ = parseTopology(dc, next_st, par);
                    add = false;
                } else {
                    const next = parseTopology(dc, next_st, null).?;
                    res.next = next;
                    next.previous = res;
                }
                c.gst_mini_object_unref(@ptrCast(caps));
            }
        }
        if (add) {
            res.stream_number = p.stream_count;
            p.stream_count += 1;
            p.current.?.stream_list = c.g_list_append(p.current.?.stream_list, res);
        } else c.g_object_unref(res);
        return res;
    }
    if (c.g_type_check_value_holds(nval, c.gst_value_list_get_type()) != 0) {
        const caps = nodeCaps(topology);
        const len = c.gst_value_list_get_size(nval);
        const cont: *dt.Container = @ptrCast(@alignCast(dt.new(dt.gst_discoverer_container_info_get_type())));
        cont.parent.caps = caps;
        if (p.global_tags) |t| cont.tags = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(@alignCast(t)))));
        var i: c.guint = 0;
        while (i < len) : (i += 1) {
            const sub = c.gst_value_get_structure(c.gst_value_list_get_value(nval, i));
            const ss = parseTopology(dc, sub, null).?;
            ss.previous = &cont.parent;
            cont.streams = c.g_list_append(cont.streams, c.g_object_ref(ss));
        }
        return &cont.parent;
    }
    return null;
}

fn setupNextLocked(dc: *Disco) void {
    const p = pv(dc);
    if (p.pending != null) {
        const ready = setupLocked(dc);
        unlock(dc);
        if (!ready) {
            if (p.processing) handleAsync(dc);
        } else _ = c.g_idle_add_full(c.G_PRIORITY_DEFAULT_IDLE, @ptrCast(&emitAndNext), c.gst_object_ref(dc), @ptrCast(&c.gst_object_unref));
    } else {
        unlock(dc);
        c.g_signal_emit(dc, signals[S_FINISHED], 0);
    }
}

fn serializeIfRequired(dc: *Disco, info: *dt.Info) void {
    const p = pv(dc);
    if (p.use_cache and p.cachefile != null and info.result == c.GST_DISCOVERER_OK) {
        const v = gst_discoverer_info_to_variant(@ptrCast(info), c.GST_DISCOVERER_SERIALIZE_ALL);
        _ = c.g_file_set_contents(p.cachefile, @ptrCast(c.g_variant_get_data(v)), @intCast(c.g_variant_get_size(v)), null);
        c.g_variant_unref(v);
    }
}

fn emitDiscovered(dc: *Disco) void {
    const p = pv(dc);
    c.g_signal_emit(dc, signals[S_DISCOVERED], 0, p.current, p.current_error);
    c.g_object_unref(p.current);
    p.current = null;
    p.stream_count = 0;
    c.g_free(p.cachefile);
    p.cachefile = null;
    p.from_cache = false;
}

fn emitAndNext(dc: *Disco) callconv(.c) c.gboolean {
    emitDiscovered(dc);
    lock(dc);
    setupNextLocked(dc);
    return 0;
}

fn collectAll(dc: *Disco) void {
    const p = pv(dc);
    if (p.timeout_source) |s| {
        c.g_source_destroy(s);
        c.g_source_unref(s);
        p.timeout_source = null;
    }
    if (p.use_cache and p.current != null and p.from_cache) return;
    const info = p.current.?;
    if (p.streams != null) {
        const pipeline = p.pipeline;
        var dur: i64 = 0;
        if (c.gst_element_query_duration(pipeline, c.GST_FORMAT_TIME, &dur) != 0) {
            info.duration = @bitCast(dur);
        } else if (info.result != c.GST_DISCOVERER_ERROR) {
            lock(dc);
            const sret = c.gst_element_set_state(pipeline, c.GST_STATE_PLAYING);
            unlock(dc);
            if (sret != c.GST_STATE_CHANGE_FAILURE) {
                for (0..2) |_| {
                    c.g_usleep(c.G_USEC_PER_SEC / 20);
                    if (c.gst_element_query_duration(pipeline, c.GST_FORMAT_TIME, &dur) != 0 and dur > 0) {
                        info.duration = @bitCast(dur);
                        break;
                    }
                }
                _ = c.gst_element_set_state(pipeline, c.GST_STATE_PAUSED);
            }
        }
        if (p.seeking_query != null and c.gst_element_query(pipeline, p.seeking_query) != 0) {
            var fmt: c.GstFormat = 0;
            var seekable: c.gboolean = 0;
            c.gst_query_parse_seeking(p.seeking_query, &fmt, &seekable, null, null);
            if (fmt == c.GST_FORMAT_TIME) info.seekable = seekable;
        }
        info.live = @intFromBool(p.target_state != c.GST_STATE_PAUSED);
        if (p.topology) |t| {
            p.stream_count = 1;
            info.stream_info = parseTopology(dc, t, null);
            if (info.stream_info) |si| si.stream_number = 0;
        }
        if (info.duration == 0 and info.stream_info != null and info.stream_info.?.next == null) {
            const si = info.stream_info.?;
            if (c.g_str_has_prefix(c.gst_structure_get_name(c.gst_caps_get_structure(si.caps, 0)), "image/") != 0) @as(*dt.Video, @ptrCast(si)).is_image = 1;
        }
    }
    if (p.all_tags) |t| info.tags = t;
    p.all_tags = null;
    serializeIfRequired(dc, info);
    if (p.is_async) emitDiscovered(dc);
}

fn asyncCb(data: c.gpointer, _: ?*c.GSource, func: [*c]c.GSourceFunc, out: [*c]c.gpointer) callconv(.c) void {
    func[0] = @ptrCast(&asyncTimeout);
    out[0] = data;
}

fn voidRef(o: c.gpointer) callconv(.c) void {
    _ = c.g_object_ref(o);
}

var cb_funcs = c.GSourceCallbackFuncs{ .ref = voidRef, .unref = c.g_object_unref, .get = asyncCb };

fn handleAsync(dc: *Disco) void {
    const p = pv(dc);
    const src = c.g_timeout_source_new(@intCast(p.timeout / @as(u64, c.GST_MSECOND)));
    c.g_source_set_callback_indirect(src, c.g_object_ref(dc), &cb_funcs);
    _ = c.g_source_attach(src, p.ctx);
    p.timeout_source = src;
}

fn handleMessage(dc: *Disco, msg: [*c]c.GstMessage) bool {
    const p = pv(dc);
    var done = false;
    var dump: [*c]const u8 = null;
    switch (msg[0].type) {
        c.GST_MESSAGE_ERROR => {
            var gerr: [*c]c.GError = null;
            var debug: [*c]u8 = null;
            c.gst_message_parse_error(msg, &gerr, &debug);
            p.current_error = gerr;
            c.g_free(debug);
            done = true;
            dump = "gst-discoverer-error";
            if (p.current.?.result != c.GST_DISCOVERER_MISSING_PLUGINS or (c.g_error_matches(gerr, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN) == 0 and c.g_error_matches(gerr, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_CODEC_NOT_FOUND) == 0)) p.current.?.result = c.GST_DISCOVERER_ERROR;
        },
        c.GST_MESSAGE_WARNING => {
            var err: [*c]c.GError = null;
            var debug: [*c]u8 = null;
            c.gst_message_parse_warning(msg, &err, &debug);
            c.g_clear_error(&err);
            c.g_free(debug);
            dump = "gst-discoverer-warning";
        },
        c.GST_MESSAGE_EOS => {
            done = true;
            dump = "gst-discoverer-eos";
        },
        c.GST_MESSAGE_APPLICATION => {
            if (c.g_strcmp0(c.gst_structure_get_name(c.gst_message_get_structure(msg)), "DiscovererDone") == 0) {
                lock(dc);
                if (p.pending_subs == 0) done = p.no_more_pads and p.target_state == p.current_state;
                unlock(dc);
                if (done) dump = "gst-discoverer-application-message";
            }
        },
        c.GST_MESSAGE_STATE_CHANGED => {
            var old: c.GstState = 0;
            var new_state: c.GstState = 0;
            var pending: c.GstState = 0;
            c.gst_message_parse_state_changed(msg, &old, &new_state, &pending);
            if (msg[0].src == @as(?*c.GstObject, @ptrCast(p.pipeline))) {
                lock(dc);
                p.current_state = new_state;
                if (p.pending_subs == 0) done = p.no_more_pads and p.target_state == p.current_state;
                unlock(dc);
            }
            if (done) dump = "gst-discoverer-target-state";
        },
        c.GST_MESSAGE_ELEMENT => {
            const s = c.gst_message_get_structure(msg);
            if (c.gst_structure_has_name(s, "missing-plugin") != 0) {
                const info = p.current.?;
                info.result = c.GST_DISCOVERER_MISSING_PLUGINS;
                if (info.misc) |m| c.gst_structure_free(m);
                info.misc = c.gst_structure_copy(s);
                c.g_ptr_array_add(info.missing, missing.gst_missing_plugin_message_get_installer_detail(msg));
            } else if (c.gst_structure_has_name(s, "stream-topology") != 0) {
                if (p.topology) |t| c.gst_structure_free(t);
                p.topology = c.gst_structure_copy(s);
            }
        },
        c.GST_MESSAGE_TAG => {
            var tl: ?*c.GstTagList = null;
            c.gst_message_parse_tag(msg, &tl);
            const scope = c.gst_tag_list_get_scope(tl);
            var tmp = c.gst_tag_list_merge(p.all_tags, tl, c.GST_TAG_MERGE_APPEND);
            if (p.all_tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
            p.all_tags = tmp;
            if (scope == c.GST_TAG_SCOPE_STREAM) {
                var l = p.streams;
                while (l != null) : (l = l[0].next) {
                    const ps: *PStream = @ptrCast(@alignCast(l[0].data));
                    if (msg[0].src == @as(?*c.GstObject, @ptrCast(ps.sink))) {
                        tmp = c.gst_tag_list_merge(ps.tags, tl, c.GST_TAG_MERGE_APPEND);
                        if (ps.tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
                        ps.tags = tmp;
                        break;
                    }
                }
            } else {
                tmp = c.gst_tag_list_merge(p.global_tags, tl, c.GST_TAG_MERGE_APPEND);
                if (p.global_tags) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
                p.global_tags = tmp;
            }
            c.gst_mini_object_unref(@ptrCast(@alignCast(tl)));
        },
        c.GST_MESSAGE_TOC => {
            var toc: ?*c.GstToc = null;
            c.gst_message_parse_toc(msg, &toc, null);
            if (p.current.?.toc) |t| c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
            p.current.?.toc = toc;
        },
        else => {},
    }
    if (dump != null) c.gst_debug_bin_to_dot_file_with_ts(@ptrCast(p.pipeline), c.GST_DEBUG_GRAPH_SHOW_ALL, dump);
    return done;
}

fn handleSync(dc: *Disco) void {
    const p = pv(dc);
    const deadline = @as(f64, @floatFromInt(p.timeout)) / @as(f64, @floatFromInt(SEC));
    const timer = c.g_timer_new();
    c.g_timer_start(timer);
    var done = false;
    while (true) {
        const msg = c.gst_bus_timed_pop(p.bus, SEC / 2);
        if (msg != null) {
            done = handleMessage(dc, msg);
            c.gst_mini_object_unref(@ptrCast(msg));
        }
        if (done or c.g_timer_elapsed(timer, null) >= deadline) break;
    }
    if (!done) p.current.?.result = c.GST_DISCOVERER_TIMEOUT;
    lock(dc);
    p.processing = false;
    unlock(dc);
    c.g_timer_stop(timer);
    c.g_timer_destroy(timer);
}

fn cachePath(uri: [*c]const u8) [*c]u8 {
    const protocol = c.gst_uri_get_protocol(uri);
    defer c.g_free(protocol);
    if (c.g_ascii_strcasecmp(protocol, "file") != 0) return null;
    const location = c.gst_uri_get_location(uri);
    defer c.g_free(location);
    var st: c.struct_stat = undefined;
    if (c.stat(location, &st) < 0) return null;
    const tmp = c.g_strdup_printf("%s-%lu-%li", location, @as(c_ulong, @intCast(st.st_size)), @as(c_long, st.st_mtim.tv_sec));
    defer c.g_free(tmp);
    const cs = c.g_checksum_new(c.G_CHECKSUM_SHA1);
    defer c.g_checksum_free(cs);
    c.g_checksum_update(cs, tmp, @intCast(c.strlen(tmp)));
    const sum = c.g_checksum_get_string(cs);
    var dir2 = [3]u8{ sum[0], sum[1], 0 };
    const cache_dir = c.g_build_filename(c.g_get_user_cache_dir(), "gstreamer-1.0", "discoverer", &dir2, @as([*c]const u8, null));
    defer c.g_free(cache_dir);
    _ = c.g_mkdir_with_parents(cache_dir, 0o777);
    return c.g_build_filename(cache_dir, sum + 2, @as([*c]const u8, null));
}

fn fromCacheFile(dc: *Disco, file: [*c]u8) OInfo {
    var data: [*c]u8 = null;
    var len: usize = 0;
    if (c.g_file_get_contents(file, &data, &len, null) == 0) {
        c.g_free(file);
        return null;
    }
    const v = c.g_variant_new_from_data(c.g_variant_type_checked_("v"), data, len, 1, null, null);
    const info = gst_discoverer_info_from_variant(v);
    c.g_variant_unref(v);
    if (info != null) {
        pv(dc).cachefile = file;
        pv(dc).from_cache = true;
    } else c.g_free(file);
    c.g_free(data);
    return info;
}

fn loadSerialized(dc: *Disco, uri: [*c]u8) callconv(.c) OInfo {
    if (!pv(dc).use_cache) return null;
    const f = cachePath(uri);
    if (f == null) return null;
    return fromCacheFile(dc, f);
}

fn setupLocked(dc: *Disco) bool {
    const p = pv(dc);
    const uri: [*c]u8 = @ptrCast(p.pending[0].data);
    p.pending = c.g_list_delete_link(p.pending, p.pending);
    var loaded: OInfo = null;
    c.g_signal_emit(dc, signals[S_LOAD], 0, uri, &loaded);
    if (loaded != null) {
        p.current = dt.info(loaded);
        c.g_free(p.current.?.uri);
        p.current.?.uri = uri;
        p.processing = false;
        p.target_state = c.GST_STATE_NULL;
        return true;
    }
    p.current = dt.info(dt.new(dt.gst_discoverer_info_get_type()));
    p.stream_count = 0;
    if (p.use_cache) p.cachefile = cachePath(uri);
    p.current.?.uri = uri;
    c.g_object_set(p.uridecodebin, "uri", uri, VNONE);
    p.processing = true;
    p.target_state = c.GST_STATE_PAUSED;
    unlock(dc);
    const ret = c.gst_element_set_state(p.pipeline, p.target_state);
    if (ret == c.GST_STATE_CHANGE_NO_PREROLL) {
        p.target_state = c.GST_STATE_PLAYING;
        _ = c.gst_element_set_state(p.pipeline, p.target_state);
    }
    lock(dc);
    return false;
}

fn cleanup(dc: *Disco) void {
    const p = pv(dc);
    lock(dc);
    p.cleanup = true;
    unlock(dc);
    c.gst_bus_set_flushing(p.bus, 1);
    lock(dc);
    if (p.current_error != null) {
        c.g_error_free(p.current_error);
        unlock(dc);
        _ = c.gst_element_set_state(p.pipeline, c.GST_STATE_NULL);
    } else unlock(dc);
    _ = c.gst_element_set_state(p.pipeline, c.GST_STATE_READY);
    c.gst_bus_set_flushing(p.bus, 0);
    lock(dc);
    p.current_error = null;
    if (p.topology) |t| {
        c.gst_structure_free(t);
        p.topology = null;
    }
    p.current = null;
    p.stream_count = 0;
    c.g_free(p.cachefile);
    p.cachefile = null;
    p.from_cache = false;
    if (p.all_tags) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        p.all_tags = null;
    }
    if (p.global_tags) |t| {
        c.gst_mini_object_unref(@ptrCast(@alignCast(t)));
        p.global_tags = null;
    }
    p.pending_subs = 0;
    p.current_state = c.GST_STATE_NULL;
    p.target_state = c.GST_STATE_NULL;
    p.no_more_pads = false;
    p.cleanup = false;
    if (p.is_async) setupNextLocked(dc) else unlock(dc);
}

fn busCb(_: ?*c.GstBus, msg: [*c]c.GstMessage, dc: *Disco) callconv(.c) void {
    const p = pv(dc);
    if (!p.processing) return;
    if (!handleMessage(dc, msg)) return;
    lock(dc);
    p.processing = false;
    unlock(dc);
    collectAll(dc);
    cleanup(dc);
}

fn asyncTimeout(dc: *Disco) callconv(.c) c.gboolean {
    if (c.g_source_is_destroyed(c.g_main_current_source()) == 0) {
        const p = pv(dc);
        p.current.?.result = c.GST_DISCOVERER_TIMEOUT;
        p.processing = false;
        collectAll(dc);
        cleanup(dc);
    }
    return 0;
}

fn startDiscovering(dc: *Disco) c.GstDiscovererResult {
    const p = pv(dc);
    lock(dc);
    if (p.cleanup) {
        unlock(dc);
        return c.GST_DISCOVERER_BUSY;
    }
    if (p.pending == null) {
        unlock(dc);
        return c.GST_DISCOVERER_URI_INVALID;
    }
    if (p.current != null) {
        unlock(dc);
        return c.GST_DISCOVERER_BUSY;
    }
    c.g_signal_emit(dc, signals[S_STARTING], 0);
    const ready = setupLocked(dc);
    unlock(dc);
    if (p.is_async) {
        if (ready) {
            const src = c.g_idle_source_new();
            c.g_source_set_callback(src, @ptrCast(&emitAndNext), c.gst_object_ref(dc), @ptrCast(&c.gst_object_unref));
            _ = c.g_source_attach(src, p.ctx);
            return c.GST_DISCOVERER_OK;
        }
        if (p.processing) handleAsync(dc);
    } else if (!ready) handleSync(dc);
    return c.GST_DISCOVERER_OK;
}

fn serializeCommon(s: *dt.Stream, flags: c.GstDiscovererSerializeFlags) ?*c.GVariant {
    var caps_s: [*c]u8 = null;
    var tags_s: [*c]u8 = null;
    var misc_s: [*c]u8 = null;
    if (s.caps != null and flags & c.GST_DISCOVERER_SERIALIZE_CAPS != 0) caps_s = c.gst_caps_to_string(s.caps);
    if (s.tags != null and flags & c.GST_DISCOVERER_SERIALIZE_TAGS != 0) tags_s = c.gst_tag_list_to_string(s.tags);
    if (s.misc != null and flags & c.GST_DISCOVERER_SERIALIZE_MISC != 0) misc_s = c.gst_structure_to_string(s.misc);
    const nextv = if (s.next) |n| toVariant(n, flags) else c.g_variant_new("()");
    const r = c.g_variant_new("(msmsmsmsv)", s.stream_id, caps_s, tags_s, misc_s, nextv);
    c.g_free(caps_s);
    c.g_free(tags_s);
    c.g_free(misc_s);
    return r;
}

fn toVariant(s: *dt.Stream, flags: c.GstDiscovererSerializeFlags) ?*c.GVariant {
    const com = serializeCommon(s, flags);
    if (dt.isContainer(s)) {
        const streams = dt.gst_discoverer_container_info_get_streams(@ptrCast(s));
        defer dt.gst_discoverer_stream_info_list_free(streams);
        if (c.g_list_length(streams) > 0) {
            var b: c.GVariantBuilder = undefined;
            c.g_variant_builder_init(&b, c.g_variant_type_checked_("a*"));
            var l = streams;
            while (l != null) : (l = l[0].next) c.g_variant_builder_add(&b, "v", toVariant(dt.stream(l[0].data), flags));
            return c.g_variant_new("(yvav)", @as(c_int, 'c'), com, &b);
        }
        return c.g_variant_new("(yvav)", @as(c_int, 'c'), com, @as(?*anyopaque, null));
    }
    if (dt.isAudio(s)) {
        const a: *dt.Audio = @ptrCast(s);
        const sv = c.g_variant_new("(uuuuumst)", a.channels, a.sample_rate, a.bitrate, a.max_bitrate, a.depth, a.language, a.channel_mask);
        return c.g_variant_new("(yvv)", @as(c_int, 'a'), com, sv);
    }
    if (dt.isVideo(s)) {
        const v: *dt.Video = @ptrCast(s);
        const sv = c.g_variant_new("(uuuuuuubuub)", v.width, v.height, v.depth, v.framerate_num, v.framerate_denom, v.par_num, v.par_denom, v.interlaced, v.bitrate, v.max_bitrate, v.is_image);
        return c.g_variant_new("(yvv)", @as(c_int, 'v'), com, sv);
    }
    if (dt.isSubtitle(s)) {
        const sub: *dt.Subtitle = @ptrCast(s);
        return c.g_variant_new("(yvv)", @as(c_int, 's'), com, c.g_variant_new("ms", sub.language));
    }
    const next = dt.gst_discoverer_stream_info_get_next(@ptrCast(s));
    if (next != null) {
        const nv = toVariant(dt.stream(next), flags);
        return c.g_variant_new("(yvv)", @as(c_int, 'n'), com, c.g_variant_new("v", nv));
    }
    return c.g_variant_new("(yv)", @as(c_int, 'n'), com);
}

fn maybeString(tuple: ?*c.GVariant, idx: usize) [*c]const u8 {
    const child = c.g_variant_get_child_value(tuple, idx);
    const maybe = c.g_variant_get_maybe(child);
    c.g_variant_unref(child);
    if (maybe == null) return null;
    const r = c.g_variant_get_string(maybe, null);
    c.g_variant_unref(maybe);
    return r;
}

fn childU32(t: ?*c.GVariant, i: usize) u32 {
    const ch = c.g_variant_get_child_value(t, i);
    defer c.g_variant_unref(ch);
    return c.g_variant_get_uint32(ch);
}

fn childU64(t: ?*c.GVariant, i: usize) u64 {
    const ch = c.g_variant_get_child_value(t, i);
    defer c.g_variant_unref(ch);
    return c.g_variant_get_uint64(ch);
}

fn childBool(t: ?*c.GVariant, i: usize) c.gboolean {
    const ch = c.g_variant_get_child_value(t, i);
    defer c.g_variant_unref(ch);
    return c.g_variant_get_boolean(ch);
}

fn parseCommon(s: *dt.Stream, com: ?*c.GVariant, info: *dt.Info) void {
    var str = maybeString(com, 0);
    if (str != null) s.stream_id = c.g_strdup(str);
    str = maybeString(com, 1);
    if (str != null) s.caps = c.gst_caps_from_string(str);
    str = maybeString(com, 2);
    if (str != null) s.tags = c.gst_tag_list_new_from_string(str);
    str = maybeString(com, 3);
    if (str != null) s.misc = c.gst_structure_new_from_string(str);
    if (c.g_variant_n_children(com) > 4) {
        const ch = c.g_variant_get_child_value(com, 4);
        const nextv = c.g_variant_get_variant(ch);
        c.g_variant_unref(ch);
        if (c.g_variant_n_children(nextv) > 0) s.next = parseDiscovery(nextv, info);
        c.g_variant_unref(nextv);
    }
    c.g_variant_unref(com);
}

fn parseDiscovery(variant: ?*c.GVariant, info: *dt.Info) ?*dt.Stream {
    const com = c.g_variant_get_child_value(variant, 1);
    var specific: ?*c.GVariant = null;
    if (c.g_variant_n_children(variant) > 2) specific = c.g_variant_get_child_value(variant, 2);
    const tch = c.g_variant_get_child_value(variant, 0);
    const kind = c.g_variant_get_byte(tch);
    c.g_variant_unref(tch);
    var s: ?*dt.Stream = null;
    blk: {
        switch (kind) {
            'c' => s = dt.stream(dt.new(dt.gst_discoverer_container_info_get_type())),
            'a' => {
                s = dt.stream(dt.new(dt.gst_discoverer_audio_info_get_type()));
                const a: *dt.Audio = @ptrCast(s.?);
                const sp = c.g_variant_get_child_value(specific, 0);
                a.channels = childU32(sp, 0);
                a.sample_rate = childU32(sp, 1);
                a.bitrate = childU32(sp, 2);
                a.max_bitrate = childU32(sp, 3);
                a.depth = childU32(sp, 4);
                const lang = maybeString(sp, 5);
                if (lang != null) a.language = c.g_strdup(lang);
                a.channel_mask = childU64(sp, 6);
                c.g_variant_unref(sp);
            },
            'v' => {
                s = dt.stream(dt.new(dt.gst_discoverer_video_info_get_type()));
                const v: *dt.Video = @ptrCast(s.?);
                const sp = c.g_variant_get_child_value(specific, 0);
                v.width = childU32(sp, 0);
                v.height = childU32(sp, 1);
                v.depth = childU32(sp, 2);
                v.framerate_num = childU32(sp, 3);
                v.framerate_denom = childU32(sp, 4);
                v.par_num = childU32(sp, 5);
                v.par_denom = childU32(sp, 6);
                v.interlaced = childBool(sp, 7);
                v.bitrate = childU32(sp, 8);
                v.max_bitrate = childU32(sp, 9);
                v.is_image = childBool(sp, 10);
                c.g_variant_unref(sp);
            },
            's' => {
                s = dt.stream(dt.new(dt.gst_discoverer_subtitle_info_get_type()));
                const sp = c.g_variant_get_child_value(specific, 0);
                const maybe = c.g_variant_get_maybe(sp);
                if (maybe != null) {
                    @as(*dt.Subtitle, @ptrCast(s.?)).language = c.g_strdup(c.g_variant_get_string(maybe, null));
                    c.g_variant_unref(maybe);
                }
                c.g_variant_unref(sp);
            },
            'n' => s = dt.stream(dt.new(dt.gst_discoverer_stream_info_get_type())),
            else => break :blk,
        }
        const st = s.?;
        parseCommon(st, c.g_variant_get_child_value(com, 0), info);
        if (!dt.isContainer(st)) info.stream_list = c.g_list_append(info.stream_list, st);
        if (info.stream_info == null) info.stream_info = st;
        if (dt.isContainer(st)) {
            const cont: *dt.Container = @ptrCast(st);
            var iter: c.GVariantIter = undefined;
            _ = c.g_variant_iter_init(&iter, specific);
            cont.tags = st.tags;
            while (true) {
                const child = c.g_variant_iter_next_value(&iter);
                if (child == null) break;
                const ci = parseDiscovery(c.g_variant_get_variant(child), info);
                if (ci) |x| cont.streams = c.g_list_append(cont.streams, c.g_object_ref(x));
                c.g_variant_unref(child);
            }
        }
    }
    c.g_variant_unref(com);
    if (specific != null) c.g_variant_unref(specific);
    c.g_variant_unref(variant);
    return s;
}

pub export fn gst_discoverer_start(dc: ODisco) void {
    if (!check.that(isDisco(dc), "gst_discoverer_start", "GST_IS_DISCOVERER (discoverer)")) return;
    const p = pv(dc);
    if (p.is_async) return;
    p.is_async = true;
    p.running = true;
    var ctx = c.g_main_context_get_thread_default();
    if (ctx == null) ctx = c.g_main_context_default();
    const src = c.gst_bus_create_watch(p.bus);
    c.g_source_set_callback(src, @ptrCast(&c.gst_bus_async_signal_func), null, null);
    _ = c.g_source_attach(src, ctx);
    p.bus_source = src;
    p.ctx = c.g_main_context_ref(ctx);
    _ = startDiscovering(@ptrCast(dc));
}

pub export fn gst_discoverer_stop(dc: ODisco) void {
    if (!check.that(isDisco(dc), "gst_discoverer_stop", "GST_IS_DISCOVERER (discoverer)")) return;
    const p = pv(dc);
    if (!p.is_async) return;
    lock(dc);
    if (p.processing) {
        if (p.bus != null) c.gst_bus_set_flushing(p.bus, 1);
        if (p.pipeline != null) _ = c.gst_element_set_state(p.pipeline, c.GST_STATE_READY);
    }
    p.running = false;
    unlock(dc);
    if (p.timeout_source) |s| {
        c.g_source_destroy(s);
        c.g_source_unref(s);
        p.timeout_source = null;
    }
    if (p.bus_source) |s| {
        c.g_source_destroy(s);
        c.g_source_unref(s);
        p.bus_source = null;
    }
    if (p.ctx) |x| {
        c.g_main_context_unref(x);
        p.ctx = null;
    }
    reset(dc);
    p.is_async = false;
}

pub export fn gst_discoverer_discover_uri_async(dc: ODisco, uri: [*c]const c.gchar) c.gboolean {
    if (!check.that(isDisco(dc), "gst_discoverer_discover_uri_async", "GST_IS_DISCOVERER (discoverer)")) return 0;
    const p = pv(dc);
    lock(dc);
    const can_run = p.pending == null;
    p.pending = c.g_list_append(p.pending, c.g_strdup(uri));
    unlock(dc);
    if (can_run) _ = startDiscovering(@ptrCast(dc));
    return 1;
}

pub export fn gst_discoverer_discover_uri(dc_in: ODisco, uri: [*c]const c.gchar, err: [*c][*c]c.GError) OInfo {
    if (!check.that(isDisco(dc_in), "gst_discoverer_discover_uri", "GST_IS_DISCOVERER (discoverer)")) return null;
    if (!check.that(uri != null, "gst_discoverer_discover_uri", "uri")) return null;
    const dc: *Disco = @ptrCast(@alignCast(dc_in));
    const p = pv(dc);
    lock(dc);
    if (p.current != null) {
        unlock(dc);
        if (err != null) err[0] = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, "Already handling a uri");
        return null;
    }
    p.pending = c.g_list_append(p.pending, c.g_strdup(uri));
    unlock(dc);
    const res = startDiscovering(dc);
    collectAll(dc);
    if (err != null) err[0] = if (p.current_error != null) c.g_error_copy(p.current_error) else null;
    if (res != c.GST_DISCOVERER_OK) p.current.?.result = res;
    const info = p.current;
    cleanup(dc);
    return @ptrCast(info);
}

pub export fn gst_discoverer_new(timeout: c.GstClockTime, err: [*c][*c]c.GError) ODisco {
    if (!check.that(timeout != el.NONE, "gst_discoverer_new", "GST_CLOCK_TIME_IS_VALID (timeout)")) return null;
    const dc: *Disco = @ptrCast(@alignCast(c.g_object_new(gst_discoverer_get_type(), "timeout", timeout, VNONE)));
    if (pv(dc).uridecodebin == null) {
        if (err != null) err[0] = c.g_error_new(c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, "Couldn't create 'uridecodebin' element");
        c.gst_object_unref(dc);
        return null;
    }
    return dc;
}

pub export fn gst_discoverer_info_to_variant(i: OInfo, flags: c.GstDiscovererSerializeFlags) ?*c.GVariant {
    const fname = "gst_discoverer_info_to_variant";
    if (!check.that(dt.isInfo(i), fname, "GST_IS_DISCOVERER_INFO (info)")) return null;
    const r = dt.info(i).result;
    if (!check.that(r == c.GST_DISCOVERER_OK or r == c.GST_DISCOVERER_MISSING_PLUGINS, fname, "gst_discoverer_info_get_result (info) == GST_DISCOVERER_OK || gst_discoverer_info_get_result (info) == GST_DISCOVERER_MISSING_PLUGINS")) return null;
    const si = dt.gst_discoverer_info_get_stream_info(i);
    const sv = toVariant(dt.stream(si), flags);
    const info = dt.info(i);
    var tags_s: [*c]u8 = null;
    if (info.tags != null and flags & c.GST_DISCOVERER_SERIALIZE_TAGS != 0) tags_s = c.gst_tag_list_to_string(info.tags);
    const iv = c.g_variant_new("(mstbmsb)", info.uri, info.duration, info.seekable, tags_s, info.live);
    c.g_free(tags_s);
    const v = c.g_variant_new("(vv)", iv, sv);
    const w = c.g_variant_new_variant(v);
    c.g_object_unref(si);
    return w;
}

pub export fn gst_discoverer_info_from_variant(variant: ?*c.GVariant) OInfo {
    if (!check.that(variant != null, "gst_discoverer_info_from_variant", "variant")) return null;
    const iv = c.g_variant_get_variant(variant);
    if (iv == null) return null;
    var ch = c.g_variant_get_child_value(iv, 0);
    const specific = c.g_variant_get_variant(ch);
    c.g_variant_unref(ch);
    ch = c.g_variant_get_child_value(iv, 1);
    const wrapped = c.g_variant_get_variant(ch);
    c.g_variant_unref(ch);
    const info = dt.info(dt.new(dt.gst_discoverer_info_get_type()));
    var str = maybeString(specific, 0);
    if (str != null) info.uri = c.g_strdup(str);
    info.duration = childU64(specific, 1);
    info.seekable = childBool(specific, 2);
    str = maybeString(specific, 3);
    if (str != null) info.tags = c.gst_tag_list_new_from_string(str);
    info.live = childBool(specific, 4);
    _ = parseDiscovery(wrapped, info);
    c.g_variant_unref(specific);
    c.g_variant_unref(iv);
    return @ptrCast(info);
}
