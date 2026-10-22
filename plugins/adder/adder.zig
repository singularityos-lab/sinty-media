const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const mx = @import("../audiomixer/mixer.zig");

const FILE = "../gst/adder/gstadder.c";
const PROP_PAD_VOLUME = 1;
const PROP_PAD_MUTE = 2;
const PROP_FILTER_CAPS = 1;
const CAPS = "audio/x-raw, format = (string) { S32LE, U32LE, S16LE, U16LE, S8, U8, F32LE, F64LE }, rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved }";

const Pad = extern struct {
    parent: cm.Pad,
    volume: f64,
    volume_i32: c.gint,
    volume_i16: c.gint,
    volume_i8: c.gint,
    mute: c.gboolean,
};

const PadClass = extern struct {
    parent: c.GstPadClass,
};

const Self = extern struct {
    element: c.GstElement,
    srcpad: ?*c.GstPad,
    collect: [*c]c.GstCollectPads,
    padcount: c.gint,
    info: c.GstAudioInfo,
    offset: i64,
    segment: c.GstSegment,
    new_segment_pending: c.gint,
    flush_stop_pending: c.gint,
    current_caps: [*c]c.GstCaps,
    filter_caps: [*c]c.GstCaps,
    pending_events: [*c]c.GList,
    send_stream_start: c.gboolean,
    send_caps: c.gboolean,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, CAPS);
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn apad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = apad(o);
    switch (id) {
        PROP_PAD_VOLUME => c.g_value_set_double(v, p.volume),
        PROP_PAD_MUTE => c.g_value_set_boolean(v, p.mute),
        else => cm.warnInvalid(FILE, o, id, spec, 103),
    }
}

fn padSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = apad(o);
    switch (id) {
        PROP_PAD_VOLUME => {
            cm.lock(p);
            p.volume = c.g_value_get_double(v);
            p.volume_i8 = @intFromFloat(p.volume * 8);
            p.volume_i16 = @intFromFloat(p.volume * 2048);
            p.volume_i32 = @intFromFloat(p.volume * 134217728);
            cm.unlock(p);
        },
        PROP_PAD_MUTE => {
            cm.lock(p);
            p.mute = c.g_value_get_boolean(v);
            cm.unlock(p);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 129),
    }
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSetProperty;
    oc.get_property = padGetProperty;
    const flags = cm.RW | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_PAD_VOLUME, c.g_param_spec_double("volume", "Volume", "Volume of this pad", 0.0, 10.0, 1.0, flags));
    c.g_object_class_install_property(oc, PROP_PAD_MUTE, c.g_param_spec_boolean("mute", "Mute", "Mute this pad", 0, flags));
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    apad(inst).volume = 1.0;
    apad(inst).mute = 0;
}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_pad_get_type(), "GstAdderPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

fn sinkGetCaps(pad: ?*c.GstPad, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const s = me(cm.padParent(pad));
    cm.lock(s);
    var filter_caps = s.filter_caps;
    if (filter_caps != null) {
        filter_caps = if (filter != null) c.gst_caps_intersect_full(filter, filter_caps, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_ref(filter_caps);
    } else filter_caps = if (filter != null) c.gst_caps_ref(filter) else null;
    cm.unlock(s);
    if (filter_caps != null and c.gst_caps_is_empty(filter_caps) != 0) return filter_caps;
    const peer = c.gst_pad_peer_query_caps(s.srcpad, filter_caps);
    cm.lock(s);
    var current = if (s.current_caps != null) c.gst_caps_ref(s.current_caps) else null;
    if (current == null) {
        current = c.gst_pad_get_pad_template_caps(pad);
        if (current == null) current = c.gst_caps_new_any();
    }
    cm.unlock(s);
    var result: [*c]c.GstCaps = undefined;
    if (peer != null) {
        result = c.gst_caps_intersect_full(peer, current, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(peer);
        c.gst_caps_unref(current);
    } else if (filter_caps != null) {
        result = c.gst_caps_intersect_full(filter_caps, current, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(current);
    } else result = current;
    result = c.gst_caps_make_writable(result);
    for (0..c.gst_caps_get_size(result)) |i| {
        const st = c.gst_caps_get_structure(result, @intCast(i));
        const ref = c.gst_structure_copy(st);
        c.gst_structure_set(ref, "channels", c.gst_int_range_get_type(), @as(c.gint, 0), @as(c.gint, 2), @as(?*anyopaque, null));
        if (c.gst_structure_is_subset(st, ref) != 0) c.gst_structure_remove_field(st, "channel-mask");
        c.gst_structure_free(ref);
    }
    if (filter_caps != null) c.gst_caps_unref(filter_caps);
    return result;
}

fn sinkQuery(pads: [*c]c.GstCollectPads, data: [*c]c.GstCollectData, q: [*c]c.GstQuery, _: c.gpointer) callconv(.c) c.gboolean {
    if (cm.queryType(q) != c.GST_QUERY_CAPS) return c.gst_collect_pads_query_default(pads, data, q, 0);
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    const caps = sinkGetCaps(data.*.pad, filter);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn setCaps(s: *Self, pad: ?*c.GstPad, orig: [*c]c.GstCaps) bool {
    const caps = c.gst_caps_copy(orig);
    defer c.gst_caps_unref(caps);
    const st = c.gst_caps_get_structure(caps, 0);
    var channels: c.gint = 0;
    if (c.gst_structure_get_int(st, "channels", &channels) != 0 and channels <= 2) c.gst_structure_remove_field(st, "channel-mask");
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return false;
    cm.lock(s);
    if (s.current_caps != null) {
        if (c.gst_audio_info_is_equal(&info, &s.info) != 0) {
            cm.unlock(s);
            return true;
        }
        cm.unlock(s);
        _ = c.gst_pad_push_event(pad, c.gst_event_new_reconfigure());
        return false;
    }
    s.current_caps = c.gst_caps_ref(caps);
    s.info = info;
    cm.unlock(s);
    return true;
}

fn queryDuration(s: *Self, q: [*c]c.GstQuery) bool {
    var format: c.GstFormat = 0;
    c.gst_query_parse_duration(q, &format, null);
    var max: i64 = -1;
    var res = true;
    var done = false;
    const it = c.gst_element_iterate_sink_pads(@ptrCast(s));
    var item = std.mem.zeroes(c.GValue);
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_DONE => done = true,
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(c.g_value_get_object(&item));
                var duration: i64 = 0;
                res = res and c.gst_pad_peer_query_duration(pad, format, &duration) != 0;
                if (res) {
                    if (duration == -1) {
                        max = duration;
                        done = true;
                    } else if (duration > max) max = duration;
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                max = -1;
                res = true;
                c.gst_iterator_resync(it);
            },
            else => {
                res = false;
                done = true;
            },
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    if (res) c.gst_query_set_duration(q, format, max);
    return res;
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var format: c.GstFormat = 0;
            c.gst_query_parse_position(q, &format, null);
            switch (format) {
                c.GST_FORMAT_TIME => c.gst_query_set_position(q, format, @bitCast(s.segment.position)),
                c.GST_FORMAT_DEFAULT => c.gst_query_set_position(q, format, s.offset),
                else => return 0,
            }
            return 1;
        },
        c.GST_QUERY_DURATION => return @intFromBool(queryDuration(s, q)),
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

const EventData = struct {
    event: [*c]c.GstEvent,
    flush: bool,
};

fn forwardEventFunc(val: [*c]const c.GValue, ret: [*c]c.GValue, data: c.gpointer) callconv(.c) c.gboolean {
    const d: *EventData = @ptrCast(@alignCast(data));
    const pad: ?*c.GstPad = @ptrCast(c.g_value_get_object(val));
    _ = c.gst_event_ref(d.event);
    const peer = c.gst_pad_get_peer(pad);
    if (peer == null or c.gst_pad_send_event(peer, d.event) == 0) {
        if (peer == null) c.gst_event_unref(d.event);
        if (d.flush) _ = c.gst_pad_send_event(pad, c.gst_event_new_flush_stop(1));
    } else c.g_value_set_boolean(ret, 1);
    if (peer != null) c.gst_object_unref(peer);
    return 1;
}

fn forwardEvent(s: *Self, e: [*c]c.GstEvent, flush: bool) bool {
    var data = EventData{ .event = e, .flush = flush };
    var vret = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&vret, c.G_TYPE_BOOLEAN);
    c.g_value_set_boolean(&vret, 0);
    const it = c.gst_element_iterate_sink_pads(@ptrCast(s));
    var ret = false;
    while (true) {
        switch (c.gst_iterator_fold(it, forwardEventFunc, &vret, &data)) {
            c.GST_ITERATOR_RESYNC => {
                c.gst_iterator_resync(it);
                c.g_value_set_boolean(&vret, 1);
            },
            c.GST_ITERATOR_OK, c.GST_ITERATOR_DONE => {
                ret = c.g_value_get_boolean(&vret) != 0;
                break;
            },
            else => break,
        }
    }
    c.gst_iterator_free(it);
    c.gst_event_unref(e);
    return ret;
}

fn srcEvent(_: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.eventType(e)) {
        c.GST_EVENT_SEEK => {
            var flags: c.GstSeekFlags = 0;
            var rate: f64 = 0;
            var st: c.GstSeekType = 0;
            var sp: c.GstSeekType = 0;
            var start: i64 = 0;
            var stop: i64 = 0;
            var format: c.GstFormat = 0;
            c.gst_event_parse_seek(e, &rate, &format, &flags, &st, &start, &sp, &stop);
            if (st != c.GST_SEEK_TYPE_NONE and st != c.GST_SEEK_TYPE_SET) return 0;
            if (sp != c.GST_SEEK_TYPE_NONE and sp != c.GST_SEEK_TYPE_SET) return 0;
            if (format != s.segment.format) return 0;
            const flush = flags & c.GST_SEEK_FLAG_FLUSH != 0;
            if (flush) {
                _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_flush_start());
                c.gst_collect_pads_set_flushing(s.collect, 1);
                c.g_rec_mutex_lock(&s.collect.*.stream_lock);
                s.flush_stop_pending = 1;
                c.g_rec_mutex_unlock(&s.collect.*.stream_lock);
            }
            c.g_rec_mutex_lock(&s.collect.*.stream_lock);
            if (s.segment.stop != cm.CLOCK_NONE) s.segment.position = s.segment.stop;
            _ = c.gst_segment_do_seek(&s.segment, rate, format, flags, st, @bitCast(start), sp, @bitCast(stop), null);
            if (flush) c.gst_collect_pads_set_flushing(s.collect, 1);
            c.g_rec_mutex_unlock(&s.collect.*.stream_lock);
            @atomicStore(c.gint, &s.new_segment_pending, 1, .seq_cst);
            const result = forwardEvent(s, e, flush);
            if (@cmpxchgStrong(c.gint, &s.flush_stop_pending, 1, 0, .seq_cst, .seq_cst) == null) _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_flush_stop(1));
            return @intFromBool(result);
        },
        c.GST_EVENT_QOS, c.GST_EVENT_NAVIGATION => {
            c.gst_event_unref(e);
            return 0;
        },
        else => return @intFromBool(forwardEvent(s, e, false)),
    }
}

fn unrefEvents(list: *[*c]c.GList) void {
    var l = list.*;
    while (l != null) : (l = l.*.next) c.gst_event_unref(@ptrCast(@alignCast(l.*.data)));
    c.g_list_free(list.*);
    list.* = null;
}

fn sinkEvent(pads: [*c]c.GstCollectPads, data: [*c]c.GstCollectData, e_in: [*c]c.GstEvent, user: c.gpointer) callconv(.c) c.gboolean {
    const s = me(user);
    var e = e_in;
    var res: c.gboolean = 1;
    var discard: c.gboolean = 0;
    switch (cm.eventType(e)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            res = @intFromBool(setCaps(s, data.*.pad, caps));
            c.gst_event_unref(e);
            e = null;
        },
        c.GST_EVENT_FLUSH_START => {
            res = c.gst_collect_pads_event_default(pads, data, e, discard);
            e = null;
            c.g_rec_mutex_lock(&s.collect.*.stream_lock);
            s.flush_stop_pending = 1;
            c.g_rec_mutex_unlock(&s.collect.*.stream_lock);
        },
        c.GST_EVENT_FLUSH_STOP => {
            @atomicStore(c.gint, &s.new_segment_pending, 1, .seq_cst);
            c.g_rec_mutex_lock(&s.collect.*.stream_lock);
            if (s.flush_stop_pending != 0) {
                res = c.gst_collect_pads_event_default(pads, data, e, discard);
                s.flush_stop_pending = 0;
                e = null;
            } else discard = 1;
            c.g_rec_mutex_unlock(&s.collect.*.stream_lock);
            if (s.pending_events != null) unrefEvents(&s.pending_events);
        },
        c.GST_EVENT_TAG => {
            s.pending_events = c.g_list_append(s.pending_events, e);
            e = null;
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            if (seg.*.rate != s.segment.rate) {
                res = 0;
                c.gst_event_unref(e);
                e = null;
            }
            discard = 1;
        },
        else => {},
    }
    if (e != null) return c.gst_collect_pads_event_default(pads, data, e, discard);
    return res;
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.collect != null) c.gst_object_unref(s.collect);
    s.collect = null;
    _ = c.gst_caps_replace(&s.filter_caps, null);
    _ = c.gst_caps_replace(&s.current_caps, null);
    if (s.pending_events != null) unrefEvents(&s.pending_events);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id != PROP_FILTER_CAPS) return cm.warnInvalid(FILE, o, id, spec, 965);
    var caps: [*c]c.GstCaps = @constCast(c.gst_value_get_caps(v));
    if (caps != null) caps = c.gst_caps_ref(caps);
    cm.lock(s);
    const old = s.filter_caps;
    s.filter_caps = caps;
    cm.unlock(s);
    if (old != null) c.gst_caps_unref(old);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id != PROP_FILTER_CAPS) return cm.warnInvalid(FILE, o, id, spec, 983);
    cm.lock(s);
    c.gst_value_set_caps(v, s.filter_caps);
    cm.unlock(s);
}

fn requestNewPad(element: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, _: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    if (templ.*.direction != c.GST_PAD_SINK) {
        c.g_log(null, c.G_LOG_LEVEL_WARNING, "gstadder: request new pad that is not a SINK pad\n");
        return null;
    }
    const s = me(element);
    const count = c.g_atomic_int_add(&s.padcount, 1);
    const name = c.g_strdup_printf("sink_%u", count);
    const pad: ?*c.GstPad = @ptrCast(c.g_object_new(padType(), "name", name, "direction", templ.*.direction, "template", templ, @as([*c]const u8, null)));
    c.g_free(name);
    _ = c.gst_collect_pads_add_pad(s.collect, pad, @sizeOf(c.GstCollectData), null, 1);
    if (c.gst_element_add_pad(element, pad) == 0) {
        _ = c.gst_collect_pads_remove_pad(s.collect, pad);
        c.gst_object_unref(pad);
        return null;
    }
    c.gst_child_proxy_child_added(@ptrCast(element), @ptrCast(@alignCast(pad)), cm.obj(pad).name);
    return pad;
}

fn releasePad(element: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(element);
    c.gst_child_proxy_child_removed(@ptrCast(element), @ptrCast(@alignCast(pad)), cm.obj(pad).name);
    if (s.collect != null) _ = c.gst_collect_pads_remove_pad(s.collect, pad);
    _ = c.gst_element_remove_pad(element, pad);
}

fn clip(_: [*c]c.GstCollectPads, data: [*c]c.GstCollectData, b: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer, user: c.gpointer) callconv(.c) c.GstFlowReturn {
    const s = me(user);
    out.* = c.gst_audio_buffer_clip(b, &data.*.segment, s.info.rate, s.info.bpf);
    return c.GST_FLOW_OK;
}

fn volume(fmt: c.GstAudioFormat, d: [*]u8, p: *Pad, n: usize) void {
    switch (fmt) {
        c.GST_AUDIO_FORMAT_U8 => mx.volumeScaled(u8, i8, i16, 3, d, p.volume_i8, n),
        c.GST_AUDIO_FORMAT_S8 => mx.volumeScaled(i8, i8, i16, 3, d, p.volume_i8, n),
        c.GST_AUDIO_FORMAT_U16LE => mx.volumeScaled(u16, i16, i32, 11, d, p.volume_i16, n),
        c.GST_AUDIO_FORMAT_S16LE => mx.volumeScaled(i16, i16, i32, 11, d, p.volume_i16, n),
        c.GST_AUDIO_FORMAT_U32LE => mx.volumeScaled(u32, i32, i64, 27, d, p.volume_i32, n),
        c.GST_AUDIO_FORMAT_S32LE => mx.volumeScaled(i32, i32, i64, 27, d, p.volume_i32, n),
        c.GST_AUDIO_FORMAT_F32LE => mx.volumeFloat(f32, d, p.volume, n),
        c.GST_AUDIO_FORMAT_F64LE => mx.volumeFloat(f64, d, p.volume, n),
        else => unreachable,
    }
}

fn mix(fmt: c.GstAudioFormat, d: [*]u8, src: [*]const u8, p: *Pad, n: usize) void {
    if (p.volume == 1.0) {
        switch (fmt) {
            c.GST_AUDIO_FORMAT_U8 => mx.addPlain(u8, d, src, n),
            c.GST_AUDIO_FORMAT_S8 => mx.addPlain(i8, d, src, n),
            c.GST_AUDIO_FORMAT_U16LE => mx.addPlain(u16, d, src, n),
            c.GST_AUDIO_FORMAT_S16LE => mx.addPlain(i16, d, src, n),
            c.GST_AUDIO_FORMAT_U32LE => mx.addPlain(u32, d, src, n),
            c.GST_AUDIO_FORMAT_S32LE => mx.addPlain(i32, d, src, n),
            c.GST_AUDIO_FORMAT_F32LE => mx.addPlain(f32, d, src, n),
            c.GST_AUDIO_FORMAT_F64LE => mx.addPlain(f64, d, src, n),
            else => unreachable,
        }
        return;
    }
    switch (fmt) {
        c.GST_AUDIO_FORMAT_U8 => mx.addScaled(u8, i8, i16, 3, d, src, p.volume_i8, n),
        c.GST_AUDIO_FORMAT_S8 => mx.addScaled(i8, i8, i16, 3, d, src, p.volume_i8, n),
        c.GST_AUDIO_FORMAT_U16LE => mx.addScaled(u16, i16, i32, 11, d, src, p.volume_i16, n),
        c.GST_AUDIO_FORMAT_S16LE => mx.addScaled(i16, i16, i32, 11, d, src, p.volume_i16, n),
        c.GST_AUDIO_FORMAT_U32LE => mx.addScaled(u32, i32, i64, 27, d, src, p.volume_i32, n),
        c.GST_AUDIO_FORMAT_S32LE => mx.addScaled(i32, i32, i64, 27, d, src, p.volume_i32, n),
        c.GST_AUDIO_FORMAT_F32LE => mx.addFloat(f32, d, src, p.volume, n),
        c.GST_AUDIO_FORMAT_F64LE => mx.addFloat(f64, d, src, p.volume, n),
        else => unreachable,
    }
}

fn collected(pads: [*c]c.GstCollectPads, user: c.gpointer) callconv(.c) c.GstFlowReturn {
    const s = me(user);
    if (s.info.finfo == null or s.info.finfo.*.format == c.GST_AUDIO_FORMAT_UNKNOWN) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Unknown data received, not negotiated"), FILE, "gst_adder_collected", 1497);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (s.flush_stop_pending != 0) {
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_flush_stop(1));
        s.flush_stop_pending = 0;
    }
    if (s.send_stream_start != 0) {
        var id: [32]u8 = undefined;
        _ = c.g_snprintf(&id, id.len, "adder-%08x", c.g_random_int());
        const ev = c.gst_event_new_stream_start(&id);
        c.gst_event_set_group_id(ev, c.gst_util_group_id_next());
        _ = c.gst_pad_push_event(s.srcpad, ev);
        s.send_stream_start = 0;
    }
    if (s.send_caps != 0) {
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_caps(s.current_caps));
        s.send_caps = 0;
    }
    const rate: c.gint = s.info.rate;
    const bps: usize = @intCast(@divTrunc(s.info.finfo.*.width, 8));
    const bpf: c.guint = @intCast(s.info.bpf);
    var discont = false;
    if (@cmpxchgStrong(c.gint, &s.new_segment_pending, 1, 0, .seq_cst, .seq_cst) == null) {
        const ev = c.gst_event_new_segment(&s.segment);
        s.segment.position = if (s.segment.rate > 0.0) s.segment.start else s.segment.stop;
        s.offset = @bitCast(c.gst_util_uint64_scale(s.segment.position, @intCast(rate), c.GST_SECOND));
        if (ev != null) _ = c.gst_pad_push_event(s.srcpad, ev);
        discont = true;
    }
    const outsize = c.gst_collect_pads_available(pads);
    var outbuf: [*c]c.GstBuffer = null;
    var gapbuf: [*c]c.GstBuffer = null;
    var outmap: c.GstMapInfo = std.mem.zeroes(c.GstMapInfo);
    var had_mute = false;
    var is_eos = true;
    const fmt = s.info.finfo.*.format;
    var l = pads.*.data;
    while (l != null) {
        const next = l.*.next;
        defer l = next;
        const data: [*c]c.GstCollectData = @ptrCast(@alignCast(l.*.data));
        const p = apad(data.*.pad);
        const inbuf = c.gst_collect_pads_take_buffer(pads, data, outsize);
        if (data.*.state & c.GST_COLLECT_PADS_STATE_EOS == 0) is_eos = false;
        if (inbuf == null) continue;
        const stream_time = c.gst_segment_to_stream_time(&data.*.segment, c.GST_FORMAT_TIME, cm.buf(inbuf).pts);
        if (stream_time != cm.CLOCK_NONE) _ = c.gst_object_sync_values(@ptrCast(@alignCast(p)), stream_time);
        cm.lock(p);
        defer cm.unlock(p);
        if (p.mute != 0 or p.volume < std.math.floatMin(f64)) {
            had_mute = true;
            c.gst_buffer_unref(inbuf);
            continue;
        }
        const is_gap = @as(*c.GstMiniObject, @ptrCast(inbuf)).flags & c.GST_BUFFER_FLAG_GAP != 0;
        if (outbuf == null) {
            if (is_gap and next != null) {
                if (gapbuf == null) gapbuf = inbuf else c.gst_buffer_unref(inbuf);
                continue;
            }
            outbuf = c.gst_buffer_make_writable(inbuf);
            _ = c.gst_buffer_map(outbuf, &outmap, c.GST_MAP_READWRITE);
            if (p.volume != 1.0) volume(fmt, outmap.data, p, outmap.size / bps);
        } else {
            if (!is_gap) {
                var inmap: c.GstMapInfo = undefined;
                _ = c.gst_buffer_map(inbuf, &inmap, c.GST_MAP_READ);
                if (inmap.size != outmap.size) c.g_assertion_message_expr(null, FILE, 1317, "gst_adder_collected", "inmap.size == outmap.size");
                mix(fmt, outmap.data, inmap.data, p, inmap.size / bps);
                c.gst_buffer_unmap(inbuf, &inmap);
            }
            c.gst_buffer_unref(inbuf);
        }
    }
    if (outbuf != null) c.gst_buffer_unmap(outbuf, &outmap);
    if (!is_eos) {
        if (outbuf == null) {
            if (gapbuf != null) {
                outbuf = gapbuf;
            } else if (had_mute) {
                outbuf = c.gst_buffer_new_allocate(null, outsize, null);
                var map: c.GstMapInfo = undefined;
                _ = c.gst_buffer_map(outbuf, &map, c.GST_MAP_WRITE);
                c.gst_audio_format_info_fill_silence(s.info.finfo, map.data, outsize);
                c.gst_buffer_unmap(outbuf, &map);
                @as(*c.GstMiniObject, @ptrCast(outbuf)).flags |= c.GST_BUFFER_FLAG_GAP;
            } else is_eos = true;
        } else if (gapbuf != null) c.gst_buffer_unref(gapbuf);
    }
    if (is_eos) {
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_eos());
        return c.GST_FLOW_EOS;
    }
    if (s.pending_events != null) {
        var t = s.pending_events;
        while (t != null) : (t = t.*.next) _ = c.gst_pad_push_event(s.srcpad, @ptrCast(@alignCast(t.*.data)));
        c.g_list_free(s.pending_events);
        s.pending_events = null;
    }
    const frames: i64 = @intCast(outsize / bpf);
    const next_offset = if (s.segment.rate > 0.0) s.offset + frames else s.offset - frames;
    const next_ts = c.gst_util_uint64_scale(@bitCast(next_offset), c.GST_SECOND, @intCast(rate));
    const b = cm.buf(outbuf);
    b.dts = cm.CLOCK_NONE;
    if (s.segment.rate > 0.0) {
        b.pts = s.segment.position;
        b.offset = @bitCast(s.offset);
        b.offset_end = @bitCast(next_offset);
        b.duration = next_ts -% s.segment.position;
    } else {
        b.pts = next_ts;
        b.offset = @bitCast(next_offset);
        b.offset_end = @bitCast(s.offset);
        b.duration = s.segment.position -% next_ts;
    }
    const flags = &@as(*c.GstMiniObject, @ptrCast(outbuf)).flags;
    if (discont) flags.* |= c.GST_BUFFER_FLAG_DISCONT else flags.* &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
    s.offset = next_offset;
    s.segment.position = next_ts;
    return c.gst_pad_push(s.srcpad, outbuf);
}

fn changeState(element: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(element);
    switch (t) {
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            s.offset = 0;
            s.flush_stop_pending = 0;
            s.new_segment_pending = 1;
            s.send_stream_start = 1;
            s.send_caps = 1;
            _ = c.gst_caps_replace(&s.current_caps, null);
            c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
            c.gst_collect_pads_start(s.collect);
        },
        c.GST_STATE_CHANGE_PAUSED_TO_READY => c.gst_collect_pads_stop(s.collect),
        else => {},
    }
    return parent.?.change_state.?(element, t);
}

fn proxyInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(g));
    i.get_child_by_index = mx.childByIndex;
    i.get_children_count = mx.childrenCount;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    c.g_object_class_install_property(oc, PROP_FILTER_CAPS, c.g_param_spec_boxed("caps", "Target caps", "Set target format for mixing (NULL means ANY). Setting this property takes a reference to the supplied GstCaps object.", c.gst_caps_get_type(), cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Adder", "Generic/Audio", "Add N audio channels together", "Thomas Vander Stichele <thomas at apestaart dot org>");
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    _ = c._gst_debug_category_new("adder", 0, "audio channel mixing element");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    const templ = c.gst_static_pad_template_get(&src_t);
    s.srcpad = c.gst_pad_new_from_template(templ, "src");
    c.gst_object_unref(templ);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    cm.setPadFlag(s.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    s.current_caps = null;
    c.gst_audio_info_init(&s.info);
    s.padcount = 0;
    s.filter_caps = null;
    s.collect = c.gst_collect_pads_new();
    c.gst_collect_pads_set_function(s.collect, collected, s);
    c.gst_collect_pads_set_clip_function(s.collect, clip, s);
    c.gst_collect_pads_set_event_function(s.collect, sinkEvent, s);
    c.gst_collect_pads_set_query_function(s.collect, sinkQuery, s);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstAdder", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "adder", c.GST_RANK_NONE, getType()) != 0;
}
