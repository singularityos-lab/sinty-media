const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");
const utils = @import("utils.zig");

const FILE = "../gst/playback/gsturidecodebin.c";
const DOMAIN = "gst-plugins-base-1.0";
const N: ?*anyopaque = null;
const A = std.heap.c_allocator;
const SECOND: u64 = 1000000000;

const PROP_URI = 1;
const PROP_SOURCE = 2;
const PROP_CONNECTION_SPEED = 3;
const PROP_CAPS = 4;
const PROP_SUBTITLE_ENCODING = 5;
const PROP_BUFFER_SIZE = 6;
const PROP_BUFFER_DURATION = 7;
const PROP_DOWNLOAD = 8;
const PROP_USE_BUFFERING = 9;
const PROP_FORCE_SW_DECODERS = 10;
const PROP_EXPOSE_ALL_STREAMS = 11;
const PROP_RING_BUFFER_MAX_SIZE = 12;
const PROP_POST_STREAM_TOPOLOGY = 13;

const SIG_UNKNOWN_TYPE = 0;
const SIG_AUTOPLUG_CONTINUE = 1;
const SIG_AUTOPLUG_FACTORIES = 2;
const SIG_AUTOPLUG_SELECT = 3;
const SIG_AUTOPLUG_SORT = 4;
const SIG_AUTOPLUG_QUERY = 5;
const SIG_DRAINED = 6;
const SIG_SOURCE_SETUP = 7;

const KEY_PENDING = "pending";
const KEY_GHOST = "uridecodebin.ghostpad";
const KEY_TOPOLOGY = "uridecodebin-topology";

const STREAM_URIS = [_][]const u8{ "http://", "https://", "mms://", "mmsh://", "mmsu://", "mmst://", "fd://", "myth://", "ssh://", "ftp://", "sftp://" };
const QUEUE_URIS = [_][]const u8{"cdda://"};
const ADAPTIVE = [_][]const u8{ "application/x-hls", "application/vnd.ms-sstr+xml", "application/dash+xml" };

const Stream = struct {
    probe: c.gulong = 0,
    bitrate: c.guint = 0,
};

const State = struct {
    lock: c.GMutex = undefined,
    factories_lock: c.GMutex = undefined,
    cookie: u32 = 0,
    factories: [*c]c.GList = null,
    uri: [*c]u8 = null,
    speed: u64 = 0,
    caps: [*c]c.GstCaps = null,
    encoding: [*c]u8 = null,
    is_stream: bool = false,
    is_adaptive: bool = false,
    need_queue: bool = false,
    buffer_duration: i64 = -1,
    buffer_size: c.gint = -1,
    download: bool = false,
    use_buffering: bool = false,
    force_sw: bool = false,
    source: ?*c.GstElement = null,
    queue: ?*c.GstElement = null,
    typefind: ?*c.GstElement = null,
    have_type_id: c.gulong = 0,
    decodebins: [*c]c.GSList = null,
    pending_decodebins: [*c]c.GSList = null,
    streams: ?*c.GHashTable = null,
    numpads: c.guint = 0,
    src_np: c.gulong = 0,
    src_nmp: c.gulong = 0,
    pending: c.gint = 0,
    missing: [*c]c.GList = null,
    async_pending: bool = false,
    expose_all: bool = true,
    ring_max: u64 = 0,
    post_topology: bool = false,
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

var src_t = cm.staticTemplate("src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
var signals: [8]c.guint = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
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

fn lock(s: *Self) void {
    c.g_mutex_lock(&st(s).lock);
}

fn unlock(s: *Self) void {
    c.g_mutex_unlock(&st(s).lock);
}

fn tr(s: [*c]const u8) [*c]const u8 {
    return cm.tr(DOMAIN, s);
}

fn err(s: *Self, domain: c.GQuark, code: c.gint, text: [*c]u8, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, domain, code, text, dbg, FILE, func, line);
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

fn autoplugContinue(_: ?*c.GstElement, _: ?*c.GstPad, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return 1;
}

fn updateFactories(t: *State) void {
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

fn autoplugFactories(e: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps) callconv(.c) [*c]c.GValueArray {
    const t = st(e);
    c.g_mutex_lock(&t.factories_lock);
    updateFactories(t);
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

fn unknownType(_: ?*c.GstElement, _: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    const cs = c.gst_caps_to_string(caps);
    cm.elementWarning(data, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_CODEC_NOT_FOUND, c.g_strdup_printf(tr("No decoder available for type '%s'."), cs), null, FILE, "unknown_type_cb", 1006);
    c.g_free(cs);
}

fn noMorePadsFull(e: ?*c.GstElement, s: *Self) void {
    const t = st(s);
    lock(s);
    var final = t.pending == 0;
    if (!final and c.g_object_get_data(gobj(e), KEY_PENDING) != null) {
        c.g_object_set_data(gobj(e), KEY_PENDING, null);
        t.pending -= 1;
        final = t.pending == 0;
    }
    unlock(s);
    if (!final) return;
    if (t.streams == null or c.g_hash_table_size(t.streams) == 0) {
        if (t.missing != null) {
            const str = c.g_string_new("");
            var l = t.missing;
            while (l != null) : (l = l.*.next) {
                const msg: [*c]c.GstMessage = @ptrCast(@alignCast(l.*.data));
                var dbg: [*c]u8 = null;
                c.gst_message_parse_error(msg, null, &dbg);
                _ = c.g_string_append(str, dbg);
                c.g_free(dbg);
                c.gst_message_unref(msg);
            }
            c.g_list_free(t.missing);
            t.missing = null;
            err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup_printf("no suitable plugins found:\n%s", str.*.str), "no_more_pads_full", 1074);
            _ = c.g_string_free(str, 1);
        } else err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("no suitable plugins found"), "no_more_pads_full", 1078);
    } else c.gst_element_no_more_pads(elem(s));
    asyncDone(s);
}

fn noMorePads(e: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    noMorePadsFull(e, me(data));
}

fn sourceNoMorePads(e: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    const t = st(data);
    c.g_signal_handler_disconnect(e, t.src_np);
    t.src_np = 0;
    c.g_signal_handler_disconnect(e, t.src_nmp);
    t.src_nmp = 0;
    noMorePadsFull(e, me(data));
}

fn configureBuffering(s: *Self) void {
    const t = st(s);
    if (t.buffer_size != -1) return;
    var queue: ?*c.GstElement = null;
    var bitrate: c.gint = 0;
    lock(s);
    if (t.queue) |q| queue = @ptrCast(@alignCast(c.gst_object_ref(q)));
    var it: c.GHashTableIter = undefined;
    c.g_hash_table_iter_init(&it, t.streams);
    var key: c.gpointer = null;
    var value: c.gpointer = null;
    while (c.g_hash_table_iter_next(&it, &key, &value) != 0) {
        const x: *Stream = @ptrCast(@alignCast(value));
        if (x.bitrate != 0 and bitrate >= 0) {
            bitrate +%= @bitCast(x.bitrate);
        } else bitrate = -1;
    }
    unlock(s);
    const q = queue orelse return;
    defer c.gst_object_unref(q);
    if (bitrate <= 0) return;
    var time: u64 = 0;
    c.g_object_get(gobj(q), "max-size-time", &time, N);
    if (time > 0) {
        const bytes: c.guint = @truncate(c.gst_util_uint64_scale(time, @intCast(bitrate), 8 * SECOND));
        c.g_object_set(gobj(q), "max-size-bytes", bytes, N);
    }
}

fn decodedEvent(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const s = me(data);
    const ev: ?*c.GstEvent = @ptrCast(@alignCast(info.*.data));
    if (cm.eventType(ev) != c.GST_EVENT_TAG) return c.GST_PAD_PROBE_OK;
    var list: ?*c.GstTagList = null;
    c.gst_event_parse_tag(ev, &list);
    var bitrate: c.guint = 0;
    if (c.gst_tag_list_get_uint_index(list, c.GST_TAG_NOMINAL_BITRATE, 0, &bitrate) == 0) _ = c.gst_tag_list_get_uint_index(list, c.GST_TAG_BITRATE, 0, &bitrate);
    if (bitrate == 0) return c.GST_PAD_PROBE_OK;
    lock(s);
    const x: ?*Stream = @ptrCast(@alignCast(c.g_hash_table_lookup(st(s).streams, pad)));
    unlock(s);
    if (x) |y| {
        y.bitrate = bitrate;
        c.gst_pad_remove_probe(pad, y.probe);
        configureBuffering(s);
    }
    return c.GST_PAD_PROBE_OK;
}

fn copySticky(_: ?*c.GstPad, ev: [*c]?*c.GstEvent, data: c.gpointer) callconv(.c) c.gboolean {
    _ = c.gst_pad_store_sticky_event(@ptrCast(@alignCast(data)), ev.*);
    return 1;
}

fn decodedPadAdded(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    lock(s);
    const name = c.g_strdup_printf("src_%u", t.numpads);
    t.numpads += 1;
    unlock(s);
    const tmpl = c.gst_static_pad_template_get(&src_t);
    const ghost = c.gst_ghost_pad_new_from_template(name, pad, tmpl);
    c.gst_object_unref(tmpl);
    c.g_free(name);
    c.g_object_set_data(gobj(pad), KEY_GHOST, ghost);
    const x = A.create(Stream) catch @panic("oom");
    x.* = .{ .probe = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, decodedEvent, s, null) };
    lock(s);
    _ = c.g_hash_table_insert(t.streams, pad, x);
    unlock(s);
    _ = c.gst_pad_set_active(ghost, 1);
    _ = c.gst_pad_sticky_events_foreach(pad, copySticky, ghost);
    _ = c.gst_element_add_pad(elem(s), ghost);
}

fn sourceEos(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, data: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (cm.eventType(info.*.data) == c.GST_EVENT_EOS) c.g_signal_emit(data, signals[SIG_DRAINED], 0);
    return c.GST_PAD_PROBE_OK;
}

fn exposeDecoded(e: ?*c.GstElement, pad: ?*c.GstPad, s: *Self) void {
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, sourceEos, s, null);
    decodedPadAdded(e, pad, s);
}

fn padRemoved(_: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    if (c.gst_pad_get_direction(pad) != c.GST_PAD_SRC) return;
    const ghost: ?*c.GstPad = @ptrCast(@alignCast(c.g_object_get_data(gobj(pad), KEY_GHOST) orelse return));
    _ = c.gst_ghost_pad_set_target(@ptrCast(@alignCast(ghost)), null);
    _ = c.gst_pad_set_active(pad, 0);
    _ = c.gst_element_remove_pad(elem(data), ghost);
}

fn uriPrefix(list: []const []const u8, uri: [*c]const u8) bool {
    for (list) |p| if (c.g_ascii_strncasecmp(uri, p.ptr, p.len) == 0) return true;
    return false;
}

fn adaptive(media: [*c]const u8) bool {
    const m = std.mem.span(media);
    for (ADAPTIVE) |p| if (std.mem.startsWith(u8, m, p)) return true;
    return false;
}

fn clampSpeed(spec: *c.GParamSpec, speed: u64, v: *c.GValue) bool {
    const t = spec.g_type_instance.g_class.*.g_type;
    if (t == c.G_TYPE_PARAM_UINT()) {
        const p: *c.GParamSpecUInt = @ptrCast(@alignCast(spec));
        c.g_value_set_uint64(v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT()) {
        const p: *c.GParamSpecInt = @ptrCast(@alignCast(spec));
        const lo: u64 = @bitCast(@as(i64, p.minimum));
        const hi: u64 = @bitCast(@as(i64, p.maximum));
        c.g_value_set_uint64(v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else if (t == c.G_TYPE_PARAM_UINT64()) {
        const p: *c.GParamSpecUInt64 = @ptrCast(@alignCast(spec));
        c.g_value_set_uint64(v, std.math.clamp(speed, p.minimum, p.maximum));
    } else if (t == c.G_TYPE_PARAM_INT64()) {
        const p: *c.GParamSpecInt64 = @ptrCast(@alignCast(spec));
        const lo: u64 = @bitCast(p.minimum);
        const hi: u64 = @bitCast(p.maximum);
        c.g_value_set_uint64(v, if (speed < lo) lo else if (speed > hi) hi else speed);
    } else return false;
    return true;
}

fn makeSource(s: *Self) ?*c.GstElement {
    const t = st(s);
    if (t.uri == null) {
        err(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(tr("No URI specified to play from.")), null, "gen_source_element", 1481);
        return null;
    }
    if (c.gst_uri_is_valid(t.uri) == 0) {
        err(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("Invalid URI \"%s\"."), t.uri), null, "gen_source_element", 1487);
        return null;
    }
    var e: [*c]c.GError = null;
    const source = c.gst_element_make_from_uri(c.GST_URI_SRC, t.uri, "source", &e) orelse {
        defer c.g_clear_error(&e);
        if (e != null and e.*.code == c.GST_URI_ERROR_UNSUPPORTED_PROTOCOL) {
            const prot = c.gst_uri_get_protocol(t.uri);
            if (prot == null) {
                err(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf(tr("Invalid URI \"%s\"."), t.uri), null, "gen_source_element", 1487);
                return null;
            }
            _ = c.gst_element_post_message(elem(s), c.gst_missing_uri_source_message_new(elem(s), prot));
            err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(tr("No URI handler implemented for \"%s\"."), prot), null, "gen_source_element", 1512);
            c.g_free(prot);
        } else err(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("%s", if (e != null) @as([*c]const u8, e.*.message) else @as([*c]const u8, "URI was not accepted by any element")), c.g_strdup_printf("No element accepted URI '%s'", t.uri), "gen_source_element", 1517);
        return null;
    };
    if (c.g_object_class_find_property(classOf(source), "connection-speed")) |spec| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.G_TYPE_UINT64);
        if (clampSpeed(spec, t.speed / 1000, &v)) c.g_object_set_property(gobj(source), "connection-speed", &v);
        c.g_value_unset(&v);
    }
    if (c.g_object_class_find_property(classOf(source), "subtitle-encoding")) |spec| {
        if (spec.*.value_type == c.G_TYPE_STRING) c.g_object_set(gobj(source), "subtitle-encoding", t.encoding, N);
    }
    _ = c.g_object_ref_sink(source);
    c.g_signal_emit(s, signals[SIG_SOURCE_SETUP], 0, source);
    t.is_stream = uriPrefix(&STREAM_URIS, t.uri);
    const q = c.gst_query_new_scheduling();
    if (c.gst_element_query(source, q) != 0) {
        var sflags: c.GstSchedulingFlags = 0;
        c.gst_query_parse_scheduling(q, &sflags, null, null, null);
        if (sflags & c.GST_SCHEDULING_FLAG_BANDWIDTH_LIMITED != 0) t.is_stream = true;
    }
    c.gst_query_unref(q);
    t.need_queue = uriPrefix(&QUEUE_URIS, t.uri);
    return source;
}

fn hasRawCaps(pad: ?*c.GstPad, raw: [*c]c.GstCaps) bool {
    const caps = c.gst_pad_get_current_caps(pad);
    if (caps == null) return false;
    defer c.gst_caps_unref(caps);
    if (c.gst_caps_get_size(caps) == 0 or c.gst_caps_is_empty(caps) != 0 or c.gst_caps_is_any(caps) != 0) return false;
    const i = c.gst_caps_intersect(caps, raw);
    defer c.gst_caps_unref(i);
    return c.gst_caps_is_empty(i) == 0;
}

fn missingPlugin(s: *Self, name: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    _ = func;
    _ = line;
    _ = c.gst_element_post_message(elem(s), c.gst_missing_element_message_new(elem(s), name));
    err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, c.g_strdup_printf(tr("Missing element '%s' - check your GStreamer installation."), name), null, "post_missing_plugin_error", 1572);
    asyncDone(s);
}

fn currentCaps(s: *Self) [*c]c.GstCaps {
    var raw: [*c]c.GstCaps = null;
    c.g_object_get(gobj(s), "caps", &raw, N);
    return if (raw != null) raw else utils.rawCaps();
}

const Probe = struct { raw: bool = false, out: bool = false, dynamic: bool = false };

fn analyseSource(s: *Self, use_queue: bool, r: *Probe) bool {
    const t = st(s);
    r.* = .{};
    const raw = currentCaps(s);
    defer c.gst_caps_unref(raw);
    const it = c.gst_element_iterate_src_pads(t.source);
    defer c.gst_iterator_free(it);
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    var ok = true;
    loop: while (true) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_ERROR => {
                ok = false;
                break :loop;
            },
            c.GST_ITERATOR_DONE => break :loop,
            c.GST_ITERATOR_RESYNC => {
                r.* = .{};
                c.gst_iterator_resync(it);
            },
            else => {
                var pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_dup_object(&item)));
                r.out = true;
                if (hasRawCaps(pad, raw)) {
                    r.raw = true;
                    var outelem = t.source;
                    if (use_queue) {
                        const q = c.gst_element_factory_make("queue2", null) orelse {
                            missingPlugin(s, "queue2", "analyse_source", 1655);
                            c.gst_object_unref(pad);
                            return false;
                        };
                        _ = c.gst_bin_add(binOf(s), q);
                        const sp = c.gst_element_get_static_pad(q, "sink");
                        _ = c.gst_pad_link(pad, sp);
                        c.gst_object_unref(sp);
                        t.queue = q;
                        c.gst_object_unref(pad);
                        pad = c.gst_element_get_static_pad(q, "src");
                        outelem = q;
                    }
                    exposeDecoded(outelem, pad, s);
                }
                c.gst_object_unref(pad);
                _ = c.g_value_reset(&item);
            },
        }
    }
    if (!r.out) {
        var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(classOf(t.source))));
        while (l != null) : (l = l.*.next) {
            const tp: *c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
            if (tp.direction != c.GST_PAD_SRC) continue;
            if (tp.presence == c.GST_PAD_SOMETIMES) r.dynamic = true;
            break;
        }
    }
    return ok;
}

fn removeDecoders(s: *Self, force: bool) void {
    const t = st(s);
    var l = t.decodebins;
    while (l != null) : (l = l.*.next) {
        const d: ?*c.GstElement = @ptrCast(@alignCast(l.*.data));
        c.g_object_set_data(gobj(d), KEY_TOPOLOGY, null);
        if (force) {
            _ = c.gst_element_set_state(d, c.GST_STATE_NULL);
            _ = c.gst_bin_remove(binOf(s), d);
        } else {
            _ = c.gst_element_set_state(d, c.GST_STATE_READY);
            _ = c.gst_object_ref(d);
            _ = c.gst_bin_remove(binOf(s), d);
            c.g_object_set(gobj(d), "sink-caps", @as(?*c.GstCaps, null), N);
            const caps = utils.rawCaps();
            c.g_object_set(gobj(d), "caps", caps, N);
            c.gst_caps_unref(caps);
            t.pending_decodebins = c.g_slist_prepend(t.pending_decodebins, d);
        }
    }
    c.g_slist_free(t.decodebins);
    t.decodebins = null;
    if (force) {
        var p = t.pending_decodebins;
        while (p != null) : (p = p.*.next) {
            _ = c.gst_element_set_state(@ptrCast(@alignCast(p.*.data)), c.GST_STATE_NULL);
            c.gst_object_unref(p.*.data);
        }
        c.g_slist_free(t.pending_decodebins);
        t.pending_decodebins = null;
    }
}

fn proxyUnknown(_: ?*c.GstElement, pad: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit(data, signals[SIG_UNKNOWN_TYPE], 0, pad, caps);
}

fn proxyContinue(_: ?*c.GstElement, pad: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) c.gboolean {
    var r: c.gboolean = 0;
    c.g_signal_emit(data, signals[SIG_AUTOPLUG_CONTINUE], 0, pad, caps, &r);
    return r;
}

fn proxyFactories(_: ?*c.GstElement, pad: ?*c.GstPad, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) [*c]c.GValueArray {
    var r: [*c]c.GValueArray = null;
    c.g_signal_emit(data, signals[SIG_AUTOPLUG_FACTORIES], 0, pad, caps, &r);
    return r;
}

fn proxySort(_: ?*c.GstElement, pad: ?*c.GstPad, caps: [*c]c.GstCaps, factories: [*c]c.GValueArray, data: c.gpointer) callconv(.c) [*c]c.GValueArray {
    var r: [*c]c.GValueArray = null;
    c.g_signal_emit(data, signals[SIG_AUTOPLUG_SORT], 0, pad, caps, factories, &r);
    return r;
}

fn proxySelect(_: ?*c.GstElement, pad: ?*c.GstPad, caps: [*c]c.GstCaps, f: ?*c.GstElementFactory, data: c.gpointer) callconv(.c) c.gint {
    var r: c.gint = 0;
    c.g_signal_emit(data, signals[SIG_AUTOPLUG_SELECT], 0, pad, caps, f, &r);
    return r;
}

fn proxyQuery(_: ?*c.GstElement, pad: ?*c.GstPad, e: ?*c.GstElement, q: ?*c.GstQuery, data: c.gpointer) callconv(.c) c.gboolean {
    var r: c.gboolean = 0;
    c.g_signal_emit(data, signals[SIG_AUTOPLUG_QUERY], 0, pad, e, q, &r);
    return r;
}

fn proxyDrained(_: ?*c.GstElement, data: c.gpointer) callconv(.c) void {
    c.g_signal_emit(data, signals[SIG_DRAINED], 0);
}

fn connect(o: ?*c.GstElement, name: [*c]const u8, f: anytype, s: *Self) void {
    _ = c.g_signal_connect_data(o, name, @ptrCast(f), s, null, 0);
}

fn makeDecoder(s: *Self) ?*c.GstElement {
    const t = st(s);
    var dec: ?*c.GstElement = null;
    var reused = false;
    if (t.pending_decodebins != null) {
        const first = t.pending_decodebins;
        dec = @ptrCast(@alignCast(first.*.data));
        t.pending_decodebins = c.g_slist_delete_link(t.pending_decodebins, first);
        reused = true;
    } else {
        dec = c.gst_element_factory_make("decodebin", null) orelse {
            missingPlugin(s, "decodebin", "make_decoder", 1976);
            err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No decodebin element, check your installation"), "make_decoder", 1977);
            asyncDone(s);
            return null;
        };
        if (dec.?.numsinkpads == 0) {
            c.gst_object_unref(dec);
            err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No typefind element, decodebin is unusable, check your installation"), "make_decoder", 1985);
            asyncDone(s);
            return null;
        }
        connect(dec, "unknown-type", &proxyUnknown, s);
        connect(dec, "autoplug-continue", &proxyContinue, s);
        connect(dec, "autoplug-factories", &proxyFactories, s);
        connect(dec, "autoplug-sort", &proxySort, s);
        connect(dec, "autoplug-select", &proxySelect, s);
        connect(dec, "autoplug-query", &proxyQuery, s);
        connect(dec, "drained", &proxyDrained, s);
        connect(dec, "pad-added", &decodedPadAdded, s);
        connect(dec, "pad-removed", &padRemoved, s);
        connect(dec, "no-more-pads", &noMorePads, s);
        connect(dec, "unknown-type", &unknownType, s);
    }
    c.g_object_set(gobj(dec), "force-sw-decoders", @as(c.gboolean, @intFromBool(t.force_sw)), N);
    if (t.caps != null) c.g_object_set(gobj(dec), "caps", t.caps, N);
    c.g_object_set(gobj(dec), "expose-all-streams", @as(c.gboolean, @intFromBool(t.expose_all)), "connection-speed", t.speed / 1000, "post-stream-topology", @as(c.gboolean, @intFromBool(t.post_topology)), N);
    if (!t.is_stream or t.is_adaptive) {
        const buffering = t.use_buffering or t.is_adaptive;
        c.g_object_set(gobj(dec), "use-buffering", @as(c.gboolean, @intFromBool(buffering)), N);
        if (buffering) {
            const bytes: c.guint = if (t.buffer_size == -1) 2 * 1024 * 1024 else @bitCast(t.buffer_size);
            const time: u64 = if (t.buffer_duration == -1) 5 * SECOND else @bitCast(t.buffer_duration);
            c.g_object_set(gobj(dec), "max-size-bytes", bytes, "max-size-buffers", @as(c.guint, 0), "max-size-time", time, N);
        }
    }
    c.g_object_set_data(gobj(dec), KEY_PENDING, @ptrFromInt(1));
    c.g_object_set(gobj(dec), "subtitle-encoding", t.encoding, N);
    t.pending += 1;
    _ = c.gst_bin_add(binOf(s), dec);
    t.decodebins = c.g_slist_prepend(t.decodebins, dec);
    if (reused) c.gst_object_unref(dec);
    return dec;
}

fn typeFound(tf: ?*c.GstElement, _: c.guint, caps: [*c]c.GstCaps, data: c.gpointer) callconv(.c) void {
    const s = me(data);
    const t = st(s);
    t.is_adaptive = adaptive(c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0)));
    var download = false;
    if (t.download) {
        var dur: i64 = 0;
        download = c.gst_element_query_duration(tf, c.GST_FORMAT_BYTES, &dur) != 0 and dur != -1;
    }
    const dec = makeDecoder(s) orelse return;
    var src = tf;
    var queue: ?*c.GstElement = null;
    if (!t.is_adaptive) {
        const name: [*c]const u8 = if (download) "downloadbuffer" else "queue2";
        queue = c.gst_element_factory_make(name, null) orelse {
            missingPlugin(s, name, "type_found", 2113);
            return;
        };
        t.queue = queue;
        if (download) {
            var prg = c.g_get_prgname();
            if (prg == null) prg = "GStreamer";
            const fname = c.g_strdup_printf("%s-XXXXXX", prg);
            const tmpl = c.g_build_filename(c.g_get_user_cache_dir(), fname, N);
            c.g_object_set(gobj(queue), "temp-template", tmpl, N);
            c.g_free(fname);
            c.g_free(tmpl);
        } else {
            c.g_object_set(gobj(queue), "use-buffering", @as(c.gboolean, 1), N);
            c.g_object_set(gobj(queue), "ring-buffer-max-size", t.ring_max, N);
            c.g_object_set(gobj(queue), "max-size-buffers", @as(c.gint, 0), N);
        }
        if (t.buffer_size != -1) c.g_object_set(gobj(queue), "max-size-bytes", t.buffer_size, N);
        if (t.buffer_duration != -1) c.g_object_set(gobj(queue), "max-size-time", t.buffer_duration, N);
        _ = c.gst_bin_add(binOf(s), queue);
        if (c.gst_element_link_pads(tf, "src", queue, "sink") == 0) return cantLink(s, "Can't link typefind to decodebin element", "type_found", 2106);
        src = queue;
    }
    c.g_object_set(gobj(dec), "sink-caps", caps, N);
    if (c.gst_element_link_pads(src, "src", dec, "sink") == 0) return cantLink(s, "Can't link typefind to decodebin element", "type_found", 2106);
    _ = c.gst_element_set_state(dec, c.GST_STATE_PAUSED);
    _ = c.gst_element_sync_state_with_parent(dec);
    if (queue) |q| _ = c.gst_element_sync_state_with_parent(q);
}

fn cantLink(s: *Self, comptime msg: []const u8, comptime func: []const u8, line: c.gint) void {
    err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup(msg ++ ""), func, line);
    asyncDone(s);
}

fn setupStreaming(s: *Self) bool {
    const t = st(s);
    const tf = c.gst_element_factory_make("typefind", null) orelse {
        missingPlugin(s, "typefind", "setup_streaming", 2149);
        err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, null, c.g_strdup("No typefind element, check your installation"), "setup_streaming", 2150);
        asyncDone(s);
        return false;
    };
    _ = c.gst_bin_add(binOf(s), tf);
    if (c.gst_element_link_pads(t.source, null, tf, "sink") == 0) {
        err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Can't link source to typefind element"), "setup_streaming", 2157);
        _ = c.gst_bin_remove(binOf(s), tf);
        asyncDone(s);
        return false;
    }
    t.typefind = tf;
    t.have_type_id = c.g_signal_connect_data(tf, "have-type", @ptrCast(&typeFound), s, null, 0);
    return true;
}

fn freeStream(p: c.gpointer) callconv(.c) void {
    A.destroy(@as(*Stream, @ptrCast(@alignCast(p))));
}

fn removeSource(s: *Self) void {
    const t = st(s);
    if (t.source) |src| {
        _ = c.gst_element_set_state(src, c.GST_STATE_NULL);
        if (t.src_np != 0) {
            c.g_signal_handler_disconnect(src, t.src_np);
            t.src_np = 0;
        }
        if (t.src_nmp != 0) {
            c.g_signal_handler_disconnect(src, t.src_nmp);
            t.src_nmp = 0;
        }
        cm.lock(s);
        t.source = null;
        cm.unlock(s);
        _ = c.gst_bin_remove(binOf(s), src);
    }
    if (t.queue) |q| {
        _ = c.gst_element_set_state(q, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), q);
        t.queue = null;
    }
    if (t.typefind) |tf| {
        _ = c.gst_element_set_state(tf, c.GST_STATE_NULL);
        _ = c.gst_bin_remove(binOf(s), tf);
        t.typefind = null;
    }
    if (t.streams) |h| {
        c.g_hash_table_destroy(h);
        t.streams = null;
    }
}

fn sourceNewPad(e: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const s = me(data);
    const t = st(s);
    lock(s);
    const raw = currentCaps(s);
    if (!t.post_topology and hasRawCaps(pad, raw)) {
        unlock(s);
        c.gst_caps_unref(raw);
        exposeDecoded(e, pad, s);
        return 1;
    }
    c.gst_caps_unref(raw);
    const dec = makeDecoder(s) orelse {
        unlock(s);
        return 0;
    };
    const sink = c.gst_element_get_static_pad(dec, "sink");
    if (c.gst_pad_link(pad, sink) != c.GST_PAD_LINK_OK) {
        c.gst_object_unref(sink);
        err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, null, c.g_strdup("Can't link source to decoder element"), "source_new_pad", 2268);
        unlock(s);
        asyncDone(s);
        return 0;
    }
    c.gst_object_unref(sink);
    _ = c.gst_element_sync_state_with_parent(dec);
    unlock(s);
    return 1;
}

fn isLive(src: ?*c.GstElement) bool {
    const spec = c.g_object_class_find_property(classOf(src), "is-live") orelse return false;
    if (spec.*.value_type != c.G_TYPE_BOOLEAN) return false;
    var live: c.gboolean = 0;
    c.g_object_get(gobj(src), "is-live", &live, N);
    return live != 0;
}

const ExposeAll = struct { s: *Self, res: bool };

fn exposeSourcePad(e: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *ExposeAll = @ptrCast(@alignCast(data));
    d.res = sourceNewPad(e, pad, d.s) != 0 or d.res;
    return 1;
}

fn setupSource(s: *Self) bool {
    const t = st(s);
    removeSource(s);
    t.pending = 0;
    const source = makeSource(s);
    cm.lock(s);
    t.source = source;
    cm.unlock(s);
    if (source == null) return false;
    _ = c.gst_bin_add(binOf(s), source);
    c.g_object_unref(source);
    c.g_object_notify(gobj(s), "source");
    if (isLive(source)) t.is_stream = false;
    removeDecoders(s, false);
    t.streams = c.g_hash_table_new_full(null, null, null, freeStream);
    if (c.gst_element_set_state(source, c.GST_STATE_READY) != c.GST_STATE_CHANGE_SUCCESS) {
        err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, c.g_strdup(tr("Source element can't be prepared")), null, "setup_source", 2420);
        return false;
    }
    var r: Probe = .{};
    if (!analyseSource(s, t.need_queue, &r)) {
        err(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_FAILED, c.g_strdup(tr("Source element is invalid.")), null, "setup_source", 2426);
        return false;
    }
    if (r.raw) {
        c.gst_element_no_more_pads(elem(s));
        asyncDone(s);
        return true;
    }
    if (!r.out and !r.dynamic) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "add element stream");
        return true;
    }
    if (r.dynamic) {
        t.src_np = c.g_signal_connect_data(source, "pad-added", @ptrCast(&sourceNewPad), s, null, 0);
        t.src_nmp = c.g_signal_connect_data(source, "no-more-pads", @ptrCast(&sourceNoMorePads), s, null, 0);
        c.g_object_set_data(gobj(source), KEY_PENDING, @ptrFromInt(1));
        t.pending += 1;
        return true;
    }
    if (t.is_stream) return setupStreaming(s);
    var d: ExposeAll = .{ .s = s, .res = false };
    _ = c.gst_element_foreach_src_pad(source, exposeSourcePad, &d);
    return d.res;
}

fn appendStructures(list: *c.GValue, first: *?*c.GstStructure, l_in: [*c]c.GList) void {
    var l = l_in;
    while (l != null) : (l = l.*.next) {
        const x: ?*c.GstStructure = @ptrCast(@alignCast(l.*.data));
        if (first.* == null) first.* = c.gst_structure_copy(x);
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, c.gst_structure_get_type());
        c.g_value_take_boxed(&v, c.gst_structure_copy(x));
        c.gst_value_list_append_value(list, &v);
        c.g_value_unset(&v);
    }
}

fn redirect(s: *Self, msg: [*c]c.GstMessage) [*c]c.GstMessage {
    const t = st(s);
    const sx = c.gst_message_get_structure(msg);
    if (t.speed == 0 or sx == null) return msg;
    const locs = c.gst_structure_get_value(sx, "locations") orelse return msg;
    const size = c.gst_value_list_get_size(locs);
    if (size < 2) return msg;
    var good: [*c]c.GList = null;
    var neutral: [*c]c.GList = null;
    var bad: [*c]c.GList = null;
    var i: c.guint = 0;
    while (i < size) : (i += 1) {
        const x: ?*const c.GstStructure = @ptrCast(@alignCast(c.g_value_get_boxed(c.gst_value_list_get_value(locs, i))));
        var bitrate: c.gint = 0;
        if (c.gst_structure_get_int(x, "minimum-bitrate", &bitrate) == 0 or bitrate <= 0) {
            neutral = c.g_list_append(neutral, @constCast(x));
        } else if (@as(u64, @intCast(bitrate)) > t.speed) {
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
    const out = c.gst_message_new_element(msg.*.src, first);
    c.gst_message_unref(msg);
    return out;
}

fn topologyMessage(s: *Self) [*c]c.GstMessage {
    const t = st(s);
    const agg = c.gst_structure_new_empty("stream-topology");
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    var l = t.decodebins;
    while (l != null) : (l = l.*.next) {
        var item = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&item, c.gst_structure_get_type());
        c.gst_value_set_structure(&item, @ptrCast(@alignCast(c.g_object_get_data(gobj(l.*.data), KEY_TOPOLOGY))));
        c.gst_value_list_append_and_take_value(&list, &item);
    }
    c.gst_structure_take_value(agg, "next", &list);
    const proto = c.gst_uri_get_protocol(t.uri);
    const name = c.g_strdup_printf("application/%s", proto);
    c.g_free(proto);
    const caps = c.gst_caps_new_empty_simple(name);
    c.g_free(name);
    c.gst_structure_set(agg, "caps", c.gst_caps_get_type(), caps, N);
    c.gst_caps_unref(caps);
    return c.gst_message_new_element(cm.obj(s), agg);
}

fn handleMessage(b: [*c]c.GstBin, msg_in: [*c]c.GstMessage) callconv(.c) void {
    const s = me(b);
    const t = st(s);
    var msg = msg_in;
    switch (msg.*.type) {
        c.GST_MESSAGE_ELEMENT => {
            if (c.gst_message_has_name(msg, "stream-topology") != 0) {
                if (t.pending != 0 or (t.decodebins != null and t.decodebins.*.next != null)) {
                    c.g_object_set_data_full(gobj(msg.*.src), KEY_TOPOLOGY, c.gst_structure_copy(c.gst_message_get_structure(msg)), @ptrCast(&c.gst_structure_free));
                    c.gst_message_unref(msg);
                    msg = null;
                    var all = true;
                    var l = t.decodebins;
                    while (l != null) : (l = l.*.next) {
                        if (c.g_object_get_data(gobj(l.*.data), KEY_TOPOLOGY) == null) all = false;
                    }
                    if (all) msg = topologyMessage(s);
                }
            } else if (c.gst_message_has_name(msg, "redirect") != 0) msg = redirect(s, msg);
        },
        c.GST_MESSAGE_ERROR => {
            var e: [*c]c.GError = null;
            c.gst_message_parse_error(msg, &e, null);
            if (c.g_error_matches(e, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN) != 0 or c.g_error_matches(e, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_CODEC_NOT_FOUND) != 0) {
                t.missing = c.g_list_prepend(t.missing, c.gst_message_ref(msg));
                noMorePadsFull(@ptrCast(@alignCast(msg.*.src)), s);
                c.gst_message_unref(msg);
                msg = null;
            }
            c.g_clear_error(&e);
        },
        else => {},
    }
    if (msg != null) parent_class.?.handle_message.?(b, msg);
}

const Fold = struct {
    q: ?*c.GstQuery,
    min: i64 = 0,
    max: i64 = -1,
    seekable: bool = true,
    live: bool = false,
};

const Kind = enum { duration, position, latency, seeking, generic };

fn padOfValue(item: [*c]const c.GValue) ?*c.GstPad {
    return @ptrCast(@alignCast(c.g_value_get_object(item)));
}

fn foldDuration(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (c.gst_pad_query(padOfValue(item), f.q) != 0) {
        c.g_value_set_boolean(ret, 1);
        var d: i64 = 0;
        c.gst_query_parse_duration(f.q, null, &d);
        if (d > f.max) f.max = d;
    }
    return 1;
}

fn foldPosition(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (c.gst_pad_query(padOfValue(item), f.q) != 0) {
        c.g_value_set_boolean(ret, 1);
        var p: i64 = 0;
        c.gst_query_parse_position(f.q, null, &p);
        if (p > f.max) f.max = p;
    }
    return 1;
}

fn foldLatency(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (c.gst_pad_query(padOfValue(item), f.q) != 0) {
        var live: c.gboolean = 0;
        var mn: u64 = 0;
        var mx: u64 = 0;
        c.gst_query_parse_latency(f.q, &live, &mn, &mx);
        if (live != 0) {
            const mi: i64 = @bitCast(mn);
            const ma: i64 = @bitCast(mx);
            if (mi > f.min) f.min = mi;
            if (f.max == -1) {
                f.max = ma;
            } else if (ma < f.max) f.max = ma;
            f.live = true;
        }
    } else c.g_value_set_boolean(ret, 0);
    return 1;
}

fn foldSeeking(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    if (c.gst_pad_query(padOfValue(item), f.q) != 0) {
        c.g_value_set_boolean(ret, 1);
        var sk: c.gboolean = 0;
        c.gst_query_parse_seeking(f.q, null, &sk, null, null);
        if (f.seekable) f.seekable = sk != 0;
    }
    return 1;
}

fn foldGeneric(item: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const f: *Fold = @ptrCast(@alignCast(data));
    const r = c.gst_pad_query(padOfValue(item), f.q) != 0;
    if (r) c.g_value_set_boolean(ret, 1);
    return @intFromBool(!r);
}

fn foldDone(kind: Kind, f: *Fold) void {
    var fmt: c.GstFormat = 0;
    switch (kind) {
        .duration => {
            c.gst_query_parse_duration(f.q, &fmt, null);
            c.gst_query_set_duration(f.q, fmt, f.max);
        },
        .position => {
            c.gst_query_parse_position(f.q, &fmt, null);
            c.gst_query_set_position(f.q, fmt, f.max);
        },
        .latency => c.gst_query_set_latency(f.q, @intFromBool(f.live), @bitCast(f.min), @bitCast(f.max)),
        .seeking => {
            c.gst_query_parse_seeking(f.q, &fmt, null, null, null);
            c.gst_query_set_seeking(f.q, fmt, @intFromBool(f.seekable), 0, -1);
        },
        .generic => {},
    }
}

fn query(e: [*c]c.GstElement, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const kind: Kind = switch (cm.queryType(q)) {
        c.GST_QUERY_DURATION => .duration,
        c.GST_QUERY_POSITION => .position,
        c.GST_QUERY_LATENCY => .latency,
        c.GST_QUERY_SEEKING => .seeking,
        else => .generic,
    };
    const func: c.GstIteratorFoldFunction = switch (kind) {
        .duration => foldDuration,
        .position => foldPosition,
        .latency => foldLatency,
        .seeking => foldSeeking,
        .generic => foldGeneric,
    };
    const default: c.gboolean = @intFromBool(kind == .latency);
    var f: Fold = .{ .q = q };
    var ret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&ret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&ret, default);
    const it = c.gst_element_iterate_src_pads(e);
    defer c.gst_iterator_free(it);
    while (true) {
        switch (c.gst_iterator_fold(it, func, &ret, &f)) {
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                f = .{ .q = q };
                c.g_value_set_boolean(&ret, default);
            },
            c.GST_ITERATOR_OK, c.GST_ITERATOR_DONE => {
                const res = c.g_value_get_boolean(&ret);
                if (kind != .generic and res != 0) foldDone(kind, &f);
                return res;
            },
            else => return 0,
        }
    }
}

fn syncDecoder(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c.gst_element_sync_state_with_parent(@ptrCast(@alignCast(data)));
}

fn changeState(e: [*c]c.GstElement, tr_: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    const t = st(s);
    if (tr_ == c.GST_STATE_CHANGE_READY_TO_PAUSED) asyncStart(s);
    var ret = @as(*c.GstElementClass, @ptrCast(@alignCast(parent_class.?))).change_state.?(e, tr_);
    if (ret == c.GST_STATE_CHANGE_FAILURE) {
        asyncDone(s);
        return c.GST_STATE_CHANGE_FAILURE;
    }
    switch (tr_) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            if (!setupSource(s)) {
                asyncDone(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            ret = c.GST_STATE_CHANGE_ASYNC;
            c.g_slist_foreach(t.decodebins, syncDecoder, null);
            if (t.typefind) |x| ret = c.gst_element_set_state(x, c.GST_STATE_PAUSED);
            if (ret == c.GST_STATE_CHANGE_FAILURE) {
                asyncDone(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            if (t.queue) |x| ret = c.gst_element_set_state(x, c.GST_STATE_PAUSED);
            if (ret == c.GST_STATE_CHANGE_FAILURE) {
                asyncDone(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            if (t.source) |x| ret = c.gst_element_set_state(x, c.GST_STATE_PAUSED);
            if (ret == c.GST_STATE_CHANGE_FAILURE) {
                asyncDone(s);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            if (ret == c.GST_STATE_CHANGE_SUCCESS) ret = c.GST_STATE_CHANGE_ASYNC;
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            removeDecoders(s, false);
            removeSource(s);
            asyncDone(s);
            c.g_list_free_full(t.missing, @ptrCast(&c.gst_mini_object_unref));
            t.missing = null;
        },
        c.GST_STATE_CHANGE_READY_TO_NULL => {
            removeDecoders(s, true);
            removeSource(s);
        },
        else => {},
    }
    if (ret == c.GST_STATE_CHANGE_NO_PREROLL) asyncDone(s);
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => {
            cm.lock(s);
            c.g_free(t.uri);
            t.uri = c.g_value_dup_string(v);
            cm.unlock(s);
        },
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            t.speed = c.g_value_get_uint64(v) *% 1000;
            const speed = t.speed;
            cm.unlock(s);
            lock(s);
            var l = t.decodebins;
            while (l != null) : (l = l.*.next) c.g_object_set(gobj(l.*.data), "connection-speed", speed / 1000, N);
            unlock(s);
        },
        PROP_CAPS => {
            cm.lock(s);
            if (t.caps != null) c.gst_caps_unref(t.caps);
            t.caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            cm.unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            const enc = c.g_value_get_string(v);
            lock(s);
            cm.lock(s);
            c.g_free(t.encoding);
            t.encoding = c.g_strdup(enc);
            cm.unlock(s);
            var l = t.decodebins;
            while (l != null) : (l = l.*.next) c.g_object_set(gobj(l.*.data), "subtitle-encoding", enc, N);
            unlock(s);
        },
        PROP_BUFFER_SIZE => t.buffer_size = c.g_value_get_int(v),
        PROP_BUFFER_DURATION => t.buffer_duration = c.g_value_get_int64(v),
        PROP_DOWNLOAD => t.download = c.g_value_get_boolean(v) != 0,
        PROP_USE_BUFFERING => t.use_buffering = c.g_value_get_boolean(v) != 0,
        PROP_FORCE_SW_DECODERS => t.force_sw = c.g_value_get_boolean(v) != 0,
        PROP_EXPOSE_ALL_STREAMS => t.expose_all = c.g_value_get_boolean(v) != 0,
        PROP_RING_BUFFER_MAX_SIZE => t.ring_max = c.g_value_get_uint64(v),
        PROP_POST_STREAM_TOPOLOGY => t.post_topology = c.g_value_get_boolean(v) != 0,
        else => cm.warnInvalid(FILE, o, id, spec, 894),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    switch (id) {
        PROP_URI => {
            cm.lock(s);
            c.g_value_set_string(v, t.uri);
            cm.unlock(s);
        },
        PROP_SOURCE => {
            cm.lock(s);
            c.g_value_set_object(v, t.source);
            cm.unlock(s);
        },
        PROP_CONNECTION_SPEED => {
            cm.lock(s);
            c.g_value_set_uint64(v, t.speed / 1000);
            cm.unlock(s);
        },
        PROP_CAPS => {
            cm.lock(s);
            c.g_value_set_boxed(v, t.caps);
            cm.unlock(s);
        },
        PROP_SUBTITLE_ENCODING => {
            cm.lock(s);
            c.g_value_set_string(v, t.encoding);
            cm.unlock(s);
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
        PROP_DOWNLOAD => c.g_value_set_boolean(v, @intFromBool(t.download)),
        PROP_USE_BUFFERING => c.g_value_set_boolean(v, @intFromBool(t.use_buffering)),
        PROP_FORCE_SW_DECODERS => c.g_value_set_boolean(v, @intFromBool(t.force_sw)),
        PROP_EXPOSE_ALL_STREAMS => c.g_value_set_boolean(v, @intFromBool(t.expose_all)),
        PROP_RING_BUFFER_MAX_SIZE => c.g_value_set_uint64(v, t.ring_max),
        PROP_POST_STREAM_TOPOLOGY => c.g_value_set_boolean(v, @intFromBool(t.post_topology)),
        else => cm.warnInvalid(FILE, o, id, spec, 960),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    const t = st(s);
    removeDecoders(s, true);
    c.g_mutex_clear(&t.lock);
    c.g_mutex_clear(&t.factories_lock);
    c.g_free(t.uri);
    c.g_free(t.encoding);
    if (t.factories != null) c.gst_plugin_feature_list_free(t.factories);
    if (t.caps != null) c.gst_caps_unref(t.caps);
    A.destroy(t);
    s.st = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent_class.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const caps_t = c.gst_caps_get_type();
    c.g_object_class_install_property(oc, PROP_URI, c.g_param_spec_string("uri", "URI", "URI to decode", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_SOURCE, c.g_param_spec_object("source", "Source", "Source object used", c.gst_element_get_type(), ro));
    c.g_object_class_install_property(oc, PROP_CONNECTION_SPEED, c.g_param_spec_uint64("connection-speed", "Connection Speed", "Network connection speed in kbps (0 = unknown)", 0, std.math.maxInt(u64) / 1000, 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", "Caps", "The caps on which to stop decoding. (NULL = default)", caps_t, cm.RW));
    c.g_object_class_install_property(oc, PROP_SUBTITLE_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle encoding", "Encoding to assume if input subtitles are not in UTF-8 encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_SIZE, c.g_param_spec_int("buffer-size", "Buffer size (bytes)", "Buffer size when buffering streams (-1 default value)", -1, std.math.maxInt(c.gint), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_BUFFER_DURATION, c.g_param_spec_int64("buffer-duration", "Buffer duration (ns)", "Buffer duration when buffering streams (-1 default value)", -1, std.math.maxInt(i64), -1, cm.RW));
    c.g_object_class_install_property(oc, PROP_DOWNLOAD, c.g_param_spec_boolean("download", "Download", "Attempt download buffering when buffering network streams", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_BUFFERING, c.g_param_spec_boolean("use-buffering", "Use Buffering", "Perform buffering on demuxed/parsed media", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORCE_SW_DECODERS, c.g_param_spec_boolean("force-sw-decoders", "Software Docoders Only", "Use only sofware decoders to process streams", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_EXPOSE_ALL_STREAMS, c.g_param_spec_boolean("expose-all-streams", "Expose All Streams", "Expose all streams, including those of unknown type or that don't match the 'caps' property", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_RING_BUFFER_MAX_SIZE, c.g_param_spec_uint64("ring-buffer-max-size", "Max. ring buffer size (bytes)", "Max. amount of data in the ring buffer (bytes, 0 = ring buffer disabled)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_POST_STREAM_TOPOLOGY, c.g_param_spec_boolean("post-stream-topology", "Post Stream Topology", "Post stream-topology messages", 0, cm.RW));
    const t = cm.typeOfClass(k);
    const pad_t = c.gst_pad_get_type();
    const va_t = c.g_value_array_get_type();
    signals[SIG_UNKNOWN_TYPE] = c.g_signal_new("unknown-type", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "unknown_type"), null, null, null, c.G_TYPE_NONE, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_CONTINUE] = c.g_signal_new("autoplug-continue", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_continue"), boolAccu, null, null, c.G_TYPE_BOOLEAN, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_FACTORIES] = c.g_signal_new("autoplug-factories", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_factories"), arrayAccu, null, null, va_t, 2, pad_t, caps_t);
    signals[SIG_AUTOPLUG_SORT] = c.g_signal_new("autoplug-sort", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_sort"), arrayHasValueAccu, null, null, va_t, 3, pad_t, caps_t, va_t | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    signals[SIG_AUTOPLUG_SELECT] = c.g_signal_new("autoplug-select", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_select"), selectAccu, null, null, flags.selectType(), 3, pad_t, caps_t, c.gst_element_factory_get_type());
    signals[SIG_AUTOPLUG_QUERY] = c.g_signal_new("autoplug-query", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "autoplug_query"), boolOrAccu, null, null, c.G_TYPE_BOOLEAN, 3, pad_t, c.gst_element_get_type(), c.gst_query_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    signals[SIG_DRAINED] = c.g_signal_new("drained", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "drained"), null, null, null, c.G_TYPE_NONE, 0, c.G_TYPE_NONE);
    signals[SIG_SOURCE_SETUP] = c.g_signal_new("source-setup", t, c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.G_TYPE_NONE, 1, c.gst_element_get_type());
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "URI Decoder", "Generic/Bin/Decoder", "Autoplug and decode an URI to raw media", "Wim Taymans <wim.taymans@gmail.com>");
    ec.query = query;
    ec.change_state = changeState;
    const bc: *c.GstBinClass = @ptrCast(@alignCast(k));
    bc.handle_message = handleMessage;
    const kc: *Class = @ptrCast(@alignCast(k));
    kc.autoplug_continue = autoplugContinue;
    kc.autoplug_factories = autoplugFactories;
    kc.autoplug_sort = autoplugSort;
    kc.autoplug_select = autoplugSelect;
    kc.autoplug_query = autoplugQuery;
    _ = c._gst_debug_category_new("uridecodebin", 0, "URI decoder element");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const t = A.create(State) catch @panic("oom");
    t.* = .{};
    s.st = t;
    c.g_mutex_init(&t.factories_lock);
    c.g_mutex_init(&t.lock);
    t.caps = utils.rawCaps();
    cm.obj(s).flags |= c.GST_ELEMENT_FLAG_SOURCE;
    c.gst_bin_set_suppressed_flags(binOf(s), c.GST_ELEMENT_FLAG_SOURCE | c.GST_ELEMENT_FLAG_SINK);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstURIDecodeBin", Class, Self, classInit, init);
        }
    }.f);
}
