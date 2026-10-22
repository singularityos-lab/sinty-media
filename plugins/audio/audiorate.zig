const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/audiorate/gstaudiorate.c";
const SECOND: u64 = 1000000000;
const NONE: u64 = cm.CLOCK_NONE;
const CAPS = "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved, non-interleaved }";

const PROP_IN = 1;
const PROP_OUT = 2;
const PROP_ADD = 3;
const PROP_DROP = 4;
const PROP_SILENT = 5;
const PROP_TOLERANCE = 6;
const PROP_SKIP_TO_FIRST = 7;

const Self = extern struct {
    parent: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    info: c.GstAudioInfo,
    in: u64,
    out: u64,
    add: u64,
    drop: u64,
    silent: c.gboolean,
    tolerance: u64,
    skip_to_first: c.gboolean,
    next_offset: u64,
    next_ts: u64,
    discont: c.gboolean,
    sink_segment: c.GstSegment,
    src_segment: c.GstSegment,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent_class: ?*c.GstElementClass = null;
var spec_add: ?*c.GParamSpec = null;
var spec_drop: ?*c.GParamSpec = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn toOffset(t: u64, rate: c.gint) u64 {
    return c.gst_util_uint64_scale_int_round(t, rate, @intCast(SECOND));
}

fn toTime(o: u64, rate: c.gint) u64 {
    return c.gst_util_uint64_scale_int_round(o, @intCast(SECOND), rate);
}

fn reset(r: *Self) void {
    r.next_offset = NONE;
    r.next_ts = NONE;
    r.discont = 1;
    c.gst_segment_init(&r.sink_segment, c.GST_FORMAT_UNDEFINED);
    c.gst_segment_init(&r.src_segment, c.GST_FORMAT_TIME);
}

fn setCaps(r: *Self, caps: [*c]c.GstCaps) bool {
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return false;
    const prev = r.info.rate;
    r.info = info;
    if (r.next_offset != NONE and prev > 0 and prev != info.rate) r.next_offset = toOffset(r.next_ts, info.rate);
    return true;
}

fn fillTo(r: *Self, time: u64) void {
    if (time == NONE or r.next_ts == NONE) return;
    const b = c.gst_buffer_new();
    cm.buf(b).pts = time;
    _ = chain(r.sinkpad, @ptrCast(r), b);
}

fn convertPosition(old: *c.GstSegment, new: *c.GstSegment, pos_in: u64) u64 {
    if (!cm.that(old.format == new.format, "convert_position", "old_segment->format == new_segment->format")) return NONE;
    if (pos_in == NONE) return NONE;
    var pos = pos_in +% old.base;
    if (pos < new.base) return NONE;
    pos -= new.base;
    if (pos < new.start or (new.stop != NONE and pos > new.stop)) return NONE;
    return pos;
}

fn convert(r: *Self, from: c.GstFormat, v: u64, to: c.GstFormat, out: *u64) void {
    _ = c.gst_audio_info_convert(&r.info, from, @bitCast(v), to, @ptrCast(out));
}

fn convertSegments(r: *Self) void {
    const from = r.sink_segment.format;
    const to = r.src_segment.format;
    if (from == to) {
        c.gst_segment_copy_into(&r.sink_segment, &r.src_segment);
        return;
    }
    r.src_segment.rate = r.sink_segment.rate;
    r.src_segment.flags = r.sink_segment.flags;
    r.src_segment.applied_rate = r.sink_segment.applied_rate;
    convert(r, from, r.sink_segment.start, to, &r.src_segment.start);
    convert(r, from, r.sink_segment.stop, to, &r.src_segment.stop);
    convert(r, from, r.sink_segment.time, to, &r.src_segment.time);
    convert(r, from, r.sink_segment.base, to, &r.src_segment.base);
    convert(r, from, r.sink_segment.position, to, &r.src_segment.position);
}

fn sinkEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const r = me(parent);
    var ev = ev_in;
    switch (cm.eventType(ev)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            if (setCaps(r, caps)) return c.gst_pad_push_event(r.srcpad, ev);
            c.gst_event_unref(ev);
            return 0;
        },
        c.GST_EVENT_FLUSH_STOP => {
            reset(r);
            return c.gst_pad_push_event(r.srcpad, ev);
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &r.sink_segment);
            var old: c.GstSegment = undefined;
            c.gst_segment_copy_into(&r.src_segment, &old);
            convertSegments(r);
            r.next_ts = convertPosition(&old, &r.src_segment, r.next_ts);
            r.next_offset = if (r.next_ts != NONE) toOffset(r.next_ts, r.info.rate) else NONE;
            const seq = c.gst_event_get_seqnum(ev);
            _ = c.gst_mini_object_replace(@ptrCast(&ev), null);
            ev = c.gst_event_new_segment(&r.src_segment);
            c.gst_event_set_seqnum(ev, seq);
            return c.gst_pad_push_event(r.srcpad, ev);
        },
        c.GST_EVENT_SEGMENT_DONE, c.GST_EVENT_EOS => {
            if (r.src_segment.stop != NONE) fillTo(r, r.src_segment.stop);
            return c.gst_pad_push_event(r.srcpad, ev);
        },
        c.GST_EVENT_GAP => {
            var ts: u64 = 0;
            var dur: u64 = 0;
            c.gst_event_parse_gap(ev, &ts, &dur);
            c.gst_event_unref(ev);
            if (ts != NONE) {
                if (dur != NONE) ts +%= dur;
                fillTo(r, ts);
            }
            return 1;
        },
        else => return c.gst_pad_event_default(pad, parent, ev),
    }
}

fn srcEvent(_: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    return c.gst_pad_push_event(me(parent).sinkpad, ev);
}

fn notify(r: *Self, spec: ?*c.GParamSpec) void {
    if (r.silent == 0) c.g_object_notify_by_pspec(@ptrCast(r), spec);
}

fn chain(_: ?*c.GstPad, parent: [*c]c.GstObject, b_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const r = me(parent);
    var b = b_in;
    const rate = r.info.rate;
    const bpf = r.info.bpf;
    if (bpf == 0) {
        c.gst_buffer_unref(b);
        cm.elementError(r, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("pipeline error, format was not negotiated"), FILE, "gst_audio_rate_chain", 723);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (r.next_offset == NONE) {
        r.discont = 1;
        r.next_offset = toOffset(r.src_segment.start, rate);
        r.next_ts = toTime(r.next_offset, rate);
        if (r.skip_to_first != 0 and cm.buf(b).pts != NONE) {
            r.next_offset = toOffset(cm.buf(b).pts, rate);
            r.next_ts = cm.buf(b).pts;
        }
    }
    var in_time = cm.buf(b).pts;
    if (in_time == NONE) in_time = r.next_ts;
    const meta: ?*c.GstAudioMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_meta_api_get_type())));
    const in_size = c.gst_buffer_get_size(b);
    const in_samples: u64 = if (meta) |m| m.samples else in_size / @as(u64, @intCast(bpf));
    r.in +%= in_samples;
    const in_offset = toOffset(in_time, rate);
    var in_offset_end = in_offset +% in_samples;
    const diff: i64 = @bitCast(in_time -% r.next_ts);
    const tol: i64 = @bitCast(r.tolerance);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    send: {
        if (diff <= tol and diff >= -%tol) {
            in_offset_end = r.next_offset +% in_samples;
            r.out +%= in_samples;
            break :send;
        }
        if (in_offset > r.next_offset) {
            var fills = in_offset - r.next_offset;
            while (fills > 0) {
                const cur = @min(fills, @as(u64, @intCast(rate)));
                fills -= cur;
                const fill = c.gst_buffer_new_allocate(null, cur * @as(u64, @intCast(bpf)), null);
                var map: c.GstMapInfo = undefined;
                _ = c.gst_buffer_map(fill, &map, c.GST_MAP_WRITE);
                c.gst_audio_format_info_fill_silence(r.info.finfo, map.data, map.size);
                c.gst_buffer_unmap(fill, &map);
                if (r.info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) _ = c.gst_buffer_add_audio_meta(fill, &r.info, cur, null);
                cm.buf(fill).offset = r.next_offset;
                r.next_offset += cur;
                cm.buf(fill).offset_end = r.next_offset;
                cm.buf(fill).pts = r.next_ts;
                r.next_ts = toTime(r.next_offset, rate);
                cm.buf(fill).duration = r.next_ts -% cm.buf(fill).pts;
                cm.buf(fill).mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
                if (r.discont != 0) {
                    cm.buf(fill).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
                    r.discont = 0;
                }
                const clipped = c.gst_audio_buffer_clip(fill, &r.src_segment, rate, bpf);
                if (clipped != null) ret = c.gst_pad_push(r.srcpad, clipped);
                if (ret != c.GST_FLOW_OK) {
                    c.gst_buffer_unref(b);
                    return ret;
                }
                r.out +%= cur;
                r.add +%= cur;
                notify(r, spec_add);
            }
            r.out +%= in_samples;
        } else if (in_offset < r.next_offset) {
            if (in_offset_end <= r.next_offset) {
                r.drop +%= in_samples;
                c.gst_buffer_unref(b);
                notify(r, spec_drop);
                return ret;
            }
            const trunc = r.next_offset - in_offset;
            const left = in_samples - trunc;
            b = c.gst_audio_buffer_truncate(b, bpf, trunc, left);
            r.drop +%= trunc;
            r.out +%= left;
            notify(r, spec_drop);
        }
    }
    if (c.gst_buffer_get_size(b) == 0) {
        c.gst_buffer_unref(b);
        return ret;
    }
    b = c.gst_buffer_make_writable(b);
    cm.buf(b).offset = r.next_offset;
    cm.buf(b).offset_end = in_offset_end;
    cm.buf(b).pts = r.next_ts;
    r.next_ts = toTime(in_offset_end, rate);
    cm.buf(b).duration = r.next_ts -% cm.buf(b).pts;
    if (r.discont != 0) {
        cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        r.discont = 0;
    } else if (cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
        cm.buf(b).mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_DISCONT);
    }
    const out = c.gst_audio_buffer_clip(b, &r.src_segment, rate, bpf);
    if (out != null) {
        r.src_segment.position = cm.buf(out).pts +% cm.buf(out).duration;
        ret = c.gst_pad_push(r.srcpad, out);
    }
    r.next_offset = in_offset_end;
    return ret;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const r = me(o);
    switch (id) {
        PROP_SILENT => r.silent = c.g_value_get_boolean(v),
        PROP_TOLERANCE => r.tolerance = c.g_value_get_uint64(v),
        PROP_SKIP_TO_FIRST => r.skip_to_first = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 746),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const r = me(o);
    switch (id) {
        PROP_IN => c.g_value_set_uint64(v, r.in),
        PROP_OUT => c.g_value_set_uint64(v, r.out),
        PROP_ADD => c.g_value_set_uint64(v, r.add),
        PROP_DROP => c.g_value_set_uint64(v, r.drop),
        PROP_SILENT => c.g_value_set_boolean(v, r.silent),
        PROP_TOLERANCE => c.g_value_set_uint64(v, r.tolerance),
        PROP_SKIP_TO_FIRST => c.g_value_set_boolean(v, r.skip_to_first),
        else => cm.warnInvalid(FILE, o, id, spec, 780),
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const r = me(e);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        r.in = 0;
        r.out = 0;
        r.drop = 0;
        r.add = 0;
        c.gst_audio_info_init(&r.info);
        reset(r);
    }
    return parent_class.?.change_state.?(e, t);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_class = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const ro = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;
    const max = std.math.maxInt(u64);
    c.g_object_class_install_property(oc, PROP_IN, c.g_param_spec_uint64("in", "In", "Number of input samples", 0, max, 0, ro));
    c.g_object_class_install_property(oc, PROP_OUT, c.g_param_spec_uint64("out", "Out", "Number of output samples", 0, max, 0, ro));
    spec_add = c.g_param_spec_uint64("add", "Add", "Number of added samples", 0, max, 0, ro);
    c.g_object_class_install_property(oc, PROP_ADD, spec_add);
    spec_drop = c.g_param_spec_uint64("drop", "Drop", "Number of dropped samples", 0, max, 0, ro);
    c.g_object_class_install_property(oc, PROP_DROP, spec_drop);
    c.g_object_class_install_property(oc, PROP_SILENT, c.g_param_spec_boolean("silent", "silent", "Don't emit notify for dropped and duplicated frames", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_TOLERANCE, c.g_param_spec_uint64("tolerance", "tolerance", "Only act if timestamp jitter/imperfection exceeds indicated tolerance (ns)", 0, max, 40 * 1000000, cm.RW));
    c.g_object_class_install_property(oc, PROP_SKIP_TO_FIRST, c.g_param_spec_boolean("skip-to-first", "Skip to first buffer", "Don't produce buffers before the first one we receive", 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Audio rate adjuster", "Filter/Effect/Audio", "Drops/duplicates/adjusts timestamps on audio samples to make a perfect stream", "Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const r = me(inst);
    const e: [*c]c.GstElement = @ptrCast(@alignCast(inst));
    r.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_event_function_full(r.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_chain_function_full(r.sinkpad, chain, null, null);
    cm.setPadFlag(r.sinkpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(e, r.sinkpad);
    r.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_event_function_full(r.srcpad, srcEvent, null, null);
    cm.setPadFlag(r.srcpad, c.GST_PAD_FLAG_PROXY_CAPS);
    _ = c.gst_element_add_pad(e, r.srcpad);
    r.in = 0;
    r.out = 0;
    r.drop = 0;
    r.add = 0;
    r.silent = 1;
    r.tolerance = 40 * 1000000;
    r.skip_to_first = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstAudioRate", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("audiorate", 0, "AudioRate stream fixer");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "audiorate", c.GST_RANK_NONE, getType()) != 0;
}
