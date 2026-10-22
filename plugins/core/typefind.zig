const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gsttypefindelement.c";
const DOMAIN = "gstreamer-1.0";
const NONE = cm.CLOCK_NONE;
const MIN_SIZE = 2 * 1024;
const MAX_SIZE = 128 * 1024;

const PROP_CAPS = 1;
const PROP_MINIMUM = 2;
const PROP_FORCE_CAPS = 3;

const MODE_NORMAL = 0;
const MODE_TYPEFIND = 1;
const MODE_ERROR = 2;

const Self = extern struct {
    parent: c.GstElement,
    sink: ?*c.GstPad,
    src: ?*c.GstPad,
    min_probability: c.guint,
    caps: [*c]c.GstCaps,
    mode: c.guint,
    adapter: ?*c.GstAdapter,
    cached_events: [*c]c.GList,
    force_caps: [*c]c.GstCaps,
    initial_offset: u64,
    need_segment: c.gboolean,
    need_stream_start: c.gboolean,
    segment: c.GstSegment,
    offset: u64,
    seqnum: u32,
};

const Class = extern struct {
    parent: c.GstElementClass,
    have_type: ?*const fn (*Self, c.guint, [*c]c.GstCaps) callconv(.c) void,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var sig_have_type: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn element(p: anytype) [*c]c.GstElement {
    return @ptrCast(@alignCast(p));
}

fn streamError(s: *Self, code: c.gint, text: [*c]u8, dbg: [*c]u8, comptime func: []const u8, line: c.gint) void {
    cm.elementError(s, c.gst_stream_error_quark(), code, text, dbg, FILE, func, line);
}

fn notEnough(s: *Self, line: c.gint) c.GstFlowReturn {
    streamError(s, c.GST_STREAM_ERROR_TYPE_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "Stream doesn't contain enough data.")), c.g_strdup("Can't typefind stream"), "gst_type_find_element_chain_do_typefinding", line);
    return c.GST_FLOW_ERROR;
}

fn haveType(s: *Self, _: c.guint, caps: [*c]c.GstCaps) callconv(.c) void {
    if (caps == null) c.g_assertion_message_expr(null, FILE, 181, "gst_type_find_element_have_type", "caps != NULL");
    if (cm.pad(s.src).mode == c.GST_PAD_MODE_PULL) return;
    cm.lock(s);
    var ev = c.gst_pad_get_sticky_event(s.src, c.GST_EVENT_CAPS, 0);
    if (ev != null) {
        var cur: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(ev, &cur);
        if (cur != caps) {
            c.gst_mini_object_unref(@ptrCast(ev));
            ev = c.gst_event_new_caps(caps);
        }
    } else ev = c.gst_event_new_caps(caps);
    cm.unlock(s);
    _ = c.gst_pad_push_event(s.src, ev);
}

fn emitHaveType(s: *Self, prob: c.guint, caps: [*c]c.GstCaps) void {
    cm.lock(s);
    _ = c.gst_mini_object_replace(@ptrCast(&s.caps), @ptrCast(caps));
    cm.unlock(s);
    const ev = c.gst_event_new_caps(caps);
    _ = c.gst_pad_store_sticky_event(s.src, ev);
    c.gst_mini_object_unref(@ptrCast(ev));
    c.g_signal_emit(s, sig_have_type, 0, prob, caps);
}

fn clearCaps(p: *[*c]c.GstCaps) void {
    if (p.* != null) c.gst_mini_object_unref(@ptrCast(p.*));
    p.* = null;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_MINIMUM => s.min_probability = c.g_value_get_uint(v),
        PROP_FORCE_CAPS => {
            cm.lock(s);
            clearCaps(&s.force_caps);
            s.force_caps = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 368),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CAPS => {
            cm.lock(s);
            c.g_value_set_boxed(v, s.caps);
            cm.unlock(s);
        },
        PROP_MINIMUM => c.g_value_set_uint(v, s.min_probability),
        PROP_FORCE_CAPS => {
            cm.lock(s);
            c.g_value_set_boxed(v, s.force_caps);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 396),
    }
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_SCHEDULING => return c.gst_pad_peer_query(s.sink, q),
        c.GST_QUERY_CAPS => {
            if (s.caps != null) {
                c.gst_query_set_caps_result(q, s.caps);
                return 1;
            }
            return c.gst_pad_peer_query(s.sink, q);
        },
        c.GST_QUERY_POSITION => {
            if (c.gst_pad_peer_query(s.sink, q) == 0) return 0;
            var f: c.GstFormat = 0;
            var pos: i64 = 0;
            c.gst_query_parse_position(q, &f, &pos);
            cm.lock(s);
            if (f == c.GST_FORMAT_BYTES) {
                pos -= @intCast(c.gst_adapter_available(s.adapter));
                if (pos < 0) pos = 0;
            }
            cm.unlock(s);
            c.gst_query_set_position(q, f, pos);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

fn seek(s: *Self, ev: [*c]c.GstEvent) bool {
    var rate: f64 = 0;
    var fmt: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var et: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(ev, &rate, &fmt, &flags, &st, &start, &et, &stop);
    if (fmt != c.GST_FORMAT_BYTES) return false;
    var seg = s.segment;
    _ = c.gst_segment_do_seek(&seg, rate, fmt, flags, st, @bitCast(start), et, @bitCast(stop), null);
    const flush = flags & c.GST_SEEK_FLAG_FLUSH != 0;
    if (flush) {
        _ = c.gst_pad_push_event(s.sink, c.gst_event_new_flush_start());
        _ = c.gst_pad_push_event(s.src, c.gst_event_new_flush_start());
    } else _ = c.gst_pad_pause_task(s.sink);
    cm.streamLock(s.sink);
    if (flush) {
        _ = c.gst_pad_push_event(s.sink, c.gst_event_new_flush_stop(1));
        _ = c.gst_pad_push_event(s.src, c.gst_event_new_flush_stop(1));
    }
    s.segment = seg;
    s.offset = s.segment.start;
    if (s.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) _ = c.gst_element_post_message(element(s), c.gst_message_new_segment_start(cm.obj(s), c.GST_FORMAT_BYTES, @bitCast(s.segment.start)));
    s.need_segment = 1;
    s.seqnum = c.gst_event_get_seqnum(ev);
    _ = c.gst_pad_start_task(s.sink, loop, s.sink, null);
    cm.streamUnlock(s.sink);
    return true;
}

fn srcEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    if (cm.eventType(ev) == c.GST_EVENT_RECONFIGURE) return c.gst_pad_push_event(s.sink, ev);
    if (s.mode != MODE_NORMAL) {
        c.gst_mini_object_unref(@ptrCast(ev));
        return 0;
    }
    if (s.segment.format != c.GST_FORMAT_UNDEFINED and cm.eventType(ev) == c.GST_EVENT_SEEK) {
        const r = seek(s, ev);
        c.gst_mini_object_unref(@ptrCast(ev));
        return @intFromBool(r);
    }
    return c.gst_pad_push_event(s.sink, ev);
}

fn startTypefinding(s: *Self) void {
    cm.lock(s);
    clearCaps(&s.caps);
    s.initial_offset = NONE;
    cm.unlock(s);
    s.mode = MODE_TYPEFIND;
}

fn sendCached(s: *Self) void {
    cm.lock(s);
    const list = s.cached_events;
    s.cached_events = null;
    cm.unlock(s);
    var l = list;
    while (l != null) : (l = l[0].next) _ = c.gst_pad_push_event(s.src, @ptrCast(@alignCast(l[0].data)));
    c.g_list_free(list);
}

fn stopTypefinding(s: *Self) void {
    var state: c.GstState = 0;
    _ = c.gst_element_get_state(element(s), &state, null, 0);
    const push = state >= c.GST_STATE_PAUSED and s.caps != null;
    s.mode = MODE_NORMAL;
    if (push) sendCached(s);
    cm.lock(s);
    const avail = c.gst_adapter_available(s.adapter);
    if (avail == 0) {
        cm.unlock(s);
        return;
    }
    const pts = c.gst_adapter_prev_pts(s.adapter, null);
    const dts = c.gst_adapter_prev_dts(s.adapter, null);
    const b = c.gst_adapter_take_buffer(s.adapter, avail);
    cm.buf(b).pts = pts;
    cm.buf(b).dts = dts;
    cm.buf(b).offset = s.initial_offset;
    cm.unlock(s);
    if (!push) {
        c.gst_buffer_unref(b);
        return;
    }
    const peer = c.gst_pad_get_peer(s.src);
    if (peer != null and cm.pad(peer).chainfunc == null) {
        const owner = cm.padParent(peer);
        streamError(s, c.GST_STREAM_ERROR_FAILED, c.g_strdup_printf(cm.tr(DOMAIN, "%s cannot work in push mode. The operation is not supported with this source element or protocol."), c.g_type_name(cm.typeOf(owner))), c.g_strdup_printf("Downstream pad %s:%s has no chainfunction, and the upstream element does not support pull mode", cm.padParentName(peer), cm.padName(peer)), "stop_typefinding", 634);
        s.mode = MODE_ERROR;
        c.gst_buffer_unref(b);
    } else _ = c.gst_pad_push(s.src, b);
    if (peer != null) c.gst_object_unref(peer);
}

fn setcaps(s: *Self, caps: [*c]c.GstCaps) bool {
    if (c.gst_caps_is_any(caps) != 0) return true;
    s.mode = MODE_NORMAL;
    emitHaveType(s, c.GST_TYPE_FIND_MAXIMUM, caps);
    stopTypefinding(s);
    return true;
}

fn flushCached(s: *Self) void {
    cm.lock(s);
    var l = s.cached_events;
    while (l != null) : (l = l[0].next) {
        const e: [*c]c.GstEvent = @ptrCast(@alignCast(l[0].data));
        const t = cm.eventType(e);
        if (cm.eventSticky(e) and t != c.GST_EVENT_SEGMENT and t != c.GST_EVENT_EOS) _ = c.gst_pad_store_sticky_event(s.src, e);
        c.gst_mini_object_unref(@ptrCast(e));
    }
    c.g_list_free(s.cached_events);
    s.cached_events = null;
    c.gst_adapter_clear(s.adapter);
    cm.unlock(s);
}

fn sinkEvent(_: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (s.mode) {
        MODE_TYPEFIND => switch (cm.eventType(ev)) {
            c.GST_EVENT_CAPS => {
                var caps: [*c]c.GstCaps = null;
                c.gst_event_parse_caps(ev, &caps);
                const r = setcaps(s, caps);
                c.gst_mini_object_unref(@ptrCast(ev));
                return @intFromBool(r);
            },
            c.GST_EVENT_GAP => {
                c.gst_mini_object_unref(@ptrCast(ev));
                return 1;
            },
            c.GST_EVENT_EOS => {
                _ = typefinding(s, false, true);
                return c.gst_pad_push_event(s.src, ev);
            },
            c.GST_EVENT_FLUSH_STOP => {
                flushCached(s);
                return c.gst_pad_push_event(s.src, ev);
            },
            c.GST_EVENT_FLUSH_START => return c.gst_pad_push_event(s.src, ev),
            else => {
                if (cm.eventType(ev) < c.GST_EVENT_CAPS) return c.gst_pad_push_event(s.src, ev);
                cm.lock(s);
                s.cached_events = c.g_list_append(s.cached_events, ev);
                cm.unlock(s);
                return 1;
            },
        },
        MODE_NORMAL => return c.gst_pad_push_event(s.src, ev),
        MODE_ERROR => return 0,
        else => {
            c.g_assertion_message_expr(null, FILE, 754, "gst_type_find_element_sink_event", null);
            return 0;
        },
    }
}

fn extension(pad: ?*c.GstPad) [*c]u8 {
    const q = c.gst_query_new_uri();
    defer c.gst_mini_object_unref(@ptrCast(q));
    if (c.gst_pad_peer_query(pad, q) == 0) return null;
    var uri: [*c]u8 = null;
    c.gst_query_parse_uri(q, &uri);
    if (uri == null) return null;
    defer c.g_free(uri);
    if (c.g_str_has_prefix(uri, "data:") != 0) return null;
    const u = c.gst_uri_from_string(uri) orelse return null;
    const path = c.gst_uri_get_path(u);
    c.gst_uri_unref(u);
    if (path == null) return null;
    const name = c.g_path_get_basename(path);
    c.g_free(path);
    defer c.g_free(name);
    const dot = c.strrchr(name, '.');
    if (dot == null) return null;
    return c.g_strdup(dot + 1);
}

fn byExtension(s: *Self, pad: ?*c.GstPad, prob: *c.GstTypeFindProbability) [*c]c.GstCaps {
    const ext = extension(pad);
    if (ext == null) return null;
    defer c.g_free(ext);
    const caps = c.gst_type_find_helper_for_extension(cm.obj(s), ext);
    if (caps != null) prob.* = c.GST_TYPE_FIND_MAXIMUM;
    return caps;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    switch (s.mode) {
        MODE_ERROR => return c.GST_FLOW_ERROR,
        MODE_NORMAL => return c.gst_pad_push(s.src, b),
        MODE_TYPEFIND => {
            cm.lock(s);
            if (s.initial_offset == NONE) s.initial_offset = cm.buf(b).offset;
            c.gst_adapter_push(s.adapter, b);
            cm.unlock(s);
            const r = typefinding(s, true, false);
            return if (s.mode == MODE_ERROR) c.GST_FLOW_ERROR else r;
        },
        else => {
            c.g_assertion_message_expr(null, FILE, 937, "gst_type_find_element_chain", null);
            return c.GST_FLOW_ERROR;
        },
    }
}

fn typefinding(s: *Self, check: bool, eos: bool) c.GstFlowReturn {
    var prob: c.GstTypeFindProbability = c.GST_TYPE_FIND_NONE;
    var caps: [*c]c.GstCaps = null;
    cm.lock(s);
    if (s.force_caps != null) {
        caps = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(s.force_caps))));
        prob = c.GST_TYPE_FIND_MAXIMUM;
    }
    if (caps == null) {
        const avail = c.gst_adapter_available(s.adapter);
        const have_min = if (check) avail >= MIN_SIZE else avail > 0;
        const have_max = if (check) avail >= MAX_SIZE else true;
        if (!have_min) {
            cm.unlock(s);
            return if (eos) notEnough(s, 1012) else c.GST_FLOW_OK;
        }
        const ext = extension(s.sink);
        const data = c.gst_adapter_map(s.adapter, avail);
        caps = c.gst_type_find_helper_for_data_with_extension(cm.obj(s), @ptrCast(data), avail, ext, &prob);
        c.gst_adapter_unmap(s.adapter);
        c.g_free(ext);
        if (caps == null) {
            cm.unlock(s);
            if (have_max) return noType(s);
            return if (eos) notEnough(s, 1034) else c.GST_FLOW_OK;
        }
        if (prob < s.min_probability) {
            c.gst_mini_object_unref(@ptrCast(caps));
            if (have_max) {
                cm.unlock(s);
                return noType(s);
            }
            cm.unlock(s);
            return c.GST_FLOW_OK;
        }
    }
    cm.unlock(s);
    s.mode = MODE_NORMAL;
    emitHaveType(s, prob, caps);
    stopTypefinding(s);
    c.gst_mini_object_unref(@ptrCast(caps));
    return c.GST_FLOW_OK;
}

fn noType(s: *Self) c.GstFlowReturn {
    streamError(s, c.GST_STREAM_ERROR_TYPE_NOT_FOUND, null, null, "gst_type_find_element_chain_do_typefinding", 1025);
    stopTypefinding(s);
    return c.GST_FLOW_ERROR;
}

fn getrange(_: ?*c.GstPad, par: [*c]c.GstObject, off: u64, len: c.guint, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return c.gst_pad_pull_range(me(par).sink, off, len, out);
}

fn srcMode(_: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const s = me(par);
    if (mode != c.GST_PAD_MODE_PULL) return 1;
    _ = c.gst_pad_pause_task(s.sink);
    return c.gst_pad_activate_mode(s.sink, mode, on);
}

fn pull(s: *Self, pad: ?*c.GstPad) c.GstFlowReturn {
    var found: [*c]c.GstCaps = null;
    var prob: c.GstTypeFindProbability = c.GST_TYPE_FIND_NONE;
    cm.lock(s);
    if (s.force_caps != null) {
        found = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(s.force_caps))));
        prob = c.GST_TYPE_FIND_MAXIMUM;
    }
    cm.unlock(s);
    if (found == null) {
        if (c.gst_pad_get_peer(pad)) |peer| {
            defer c.gst_object_unref(peer);
            var size: i64 = 0;
            if (c.gst_pad_query_duration(peer, c.GST_FORMAT_BYTES, &size) == 0) return c.GST_FLOW_ERROR;
            if (size == 0) {
                streamError(s, c.GST_STREAM_ERROR_TYPE_NOT_FOUND, c.g_strdup(cm.tr(DOMAIN, "Stream contains no data.")), c.g_strdup("Can't typefind empty stream"), "gst_type_find_element_loop", 1154);
                return c.GST_FLOW_ERROR;
            }
            const ext = extension(pad);
            const r = c.gst_type_find_helper_get_range_full(cm.obj(peer), cm.obj(peer).parent, @ptrCast(cm.pad(peer).getrangefunc), @bitCast(size), ext, &found, &prob);
            c.g_free(ext);
            if (r != c.GST_FLOW_OK) return r;
        }
    }
    if (found == null or prob < s.min_probability) {
        clearCaps(&found);
        found = byExtension(s, pad, &prob);
    }
    if (found == null or prob < s.min_probability) {
        streamError(s, c.GST_STREAM_ERROR_TYPE_NOT_FOUND, null, null, "gst_type_find_element_loop", 1186);
        clearCaps(&found);
        return c.GST_FLOW_ERROR;
    }
    s.mode = MODE_NORMAL;
    emitHaveType(s, prob, found);
    c.gst_mini_object_unref(@ptrCast(found));
    return c.GST_FLOW_OK;
}

fn step(s: *Self) c.GstFlowReturn {
    if (s.need_segment != 0) {
        s.need_segment = 0;
        const ev = c.gst_event_new_segment(&s.segment);
        if (s.seqnum != 0) c.gst_event_set_seqnum(ev, s.seqnum);
        _ = c.gst_pad_push_event(s.src, ev);
    }
    var out: [*c]c.GstBuffer = null;
    const r = c.gst_pad_pull_range(s.sink, s.offset, 4096, &out);
    if (r != c.GST_FLOW_OK) return r;
    s.offset += c.gst_buffer_get_size(out);
    return c.gst_pad_push(s.src, out);
}

fn loop(data: c.gpointer) callconv(.c) void {
    const pad: ?*c.GstPad = @ptrCast(@alignCast(data));
    const s = me(cm.padParent(pad));
    if (s.need_stream_start != 0) {
        const id = c.gst_pad_create_stream_id(s.src, element(s), null);
        const ev = c.gst_event_new_stream_start(id);
        c.gst_event_set_group_id(ev, c.gst_util_group_id_next());
        _ = c.gst_pad_push_event(s.src, ev);
        s.need_stream_start = 0;
        c.g_free(id);
    }
    const r = switch (s.mode) {
        MODE_TYPEFIND => pull(s, pad),
        MODE_NORMAL => step(s),
        else => c.GST_FLOW_ERROR,
    };
    if (r == c.GST_FLOW_OK) return;
    _ = c.gst_pad_pause_task(s.sink);
    var eos = false;
    if (r == c.GST_FLOW_EOS) {
        if (s.segment.flags & c.GST_SEGMENT_FLAG_SEGMENT != 0) {
            var stop: i64 = @bitCast(s.segment.stop);
            if (stop == -1) stop = @bitCast(s.offset);
            _ = c.gst_element_post_message(element(s), c.gst_message_new_segment_done(cm.obj(s), c.GST_FORMAT_BYTES, stop));
            _ = c.gst_pad_push_event(s.src, c.gst_event_new_segment_done(c.GST_FORMAT_BYTES, stop));
        } else eos = true;
    } else if (r == c.GST_FLOW_NOT_LINKED or r < c.GST_FLOW_EOS) {
        cm.flowError(s, r, FILE, "gst_type_find_element_loop", 1257);
        eos = true;
    }
    if (eos) _ = c.gst_pad_push_event(s.src, c.gst_event_new_eos());
}

fn sinkMode(pad: ?*c.GstPad, par: [*c]c.GstObject, mode: c.GstPadMode, on: c.gboolean) callconv(.c) c.gboolean {
    const s = me(par);
    switch (mode) {
        c.GST_PAD_MODE_PULL => {
            if (on != 0) {
                c.gst_segment_init(&s.segment, c.GST_FORMAT_BYTES);
                s.need_segment = 1;
                s.need_stream_start = 1;
                s.offset = 0;
                s.seqnum = 0;
                return 1;
            }
            const r = c.gst_pad_stop_task(pad);
            c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
            return r;
        },
        c.GST_PAD_MODE_PUSH => {
            if (on != 0) {
                c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
                startTypefinding(s);
            } else {
                stopTypefinding(s);
                c.gst_segment_init(&s.segment, c.GST_FORMAT_UNDEFINED);
            }
            return 1;
        },
        else => return 0,
    }
}

fn activateSink(pad: ?*c.GstPad, _: [*c]c.GstObject) callconv(.c) c.gboolean {
    const q = c.gst_query_new_scheduling();
    const ok = c.gst_pad_peer_query(pad, q) != 0 and c.gst_query_has_scheduling_mode_with_flags(q, c.GST_PAD_MODE_PULL, c.GST_SCHEDULING_FLAG_SEEKABLE) != 0;
    c.gst_mini_object_unref(@ptrCast(q));
    if (ok and c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PULL, 1) != 0) return c.gst_pad_start_task(pad, loop, pad, null);
    return c.gst_pad_activate_mode(pad, c.GST_PAD_MODE_PUSH, 1);
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    const r = parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY or t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        cm.lock(s);
        clearCaps(&s.caps);
        var l = s.cached_events;
        while (l != null) : (l = l[0].next) c.gst_mini_object_unref(@ptrCast(@alignCast(l[0].data)));
        c.g_list_free(s.cached_events);
        s.cached_events = null;
        s.mode = MODE_TYPEFIND;
        cm.unlock(s);
    }
    return r;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.adapter) |a| c.g_object_unref(a);
    s.adapter = null;
    clearCaps(&s.force_caps);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.g_object_class_install_property(oc, PROP_CAPS, c.g_param_spec_boxed("caps", cm.tr(DOMAIN, "caps"), cm.tr(DOMAIN, "detected capabilities in stream"), c.gst_caps_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.g_object_class_install_property(oc, PROP_MINIMUM, c.g_param_spec_uint("minimum", cm.tr(DOMAIN, "minimum"), "minimum probability required to accept caps", c.GST_TYPE_FIND_MINIMUM, c.GST_TYPE_FIND_MAXIMUM, c.GST_TYPE_FIND_MINIMUM, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORCE_CAPS, c.g_param_spec_boxed("force-caps", cm.tr(DOMAIN, "force caps"), cm.tr(DOMAIN, "force caps without doing a typefind"), c.gst_caps_get_type(), cm.RW));
    sig_have_type = c.g_signal_new("have-type", cm.typeOfClass(k), c.G_SIGNAL_RUN_LAST, @offsetOf(Class, "have_type"), null, null, null, c.G_TYPE_NONE, 2, c.G_TYPE_UINT, c.gst_caps_get_type() | c.G_SIGNAL_TYPE_STATIC_SCOPE);
    @as(*Class, @ptrCast(@alignCast(k))).have_type = haveType;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "TypeFind", "Generic", "Finds the media type of a stream", "Benjamin Otte <in7y118@public.uni-hamburg.de>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sink = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_activate_function_full(s.sink, activateSink, null, null);
    c.gst_pad_set_activatemode_function_full(s.sink, sinkMode, null, null);
    c.gst_pad_set_chain_function_full(s.sink, chain, null, null);
    c.gst_pad_set_event_function_full(s.sink, sinkEvent, null, null);
    cm.setPadFlag(s.sink, c.GST_PAD_FLAG_PROXY_ALLOCATION);
    _ = c.gst_element_add_pad(element(s), s.sink);
    s.src = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_activatemode_function_full(s.src, srcMode, null, null);
    c.gst_pad_set_getrange_function_full(s.src, getrange, null, null);
    c.gst_pad_set_event_function_full(s.src, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.src, srcQuery, null, null);
    c.gst_pad_use_fixed_caps(s.src);
    _ = c.gst_element_add_pad(element(s), s.src);
    s.mode = MODE_TYPEFIND;
    s.caps = null;
    s.min_probability = 1;
    s.adapter = c.gst_adapter_new();
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstTypeFindElement", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("typefind", c.GST_DEBUG_BG_YELLOW | c.GST_DEBUG_FG_GREEN, "type finding element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "typefind", c.GST_RANK_NONE, getType()) != 0;
}
