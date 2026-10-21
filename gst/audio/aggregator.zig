const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const check = @import("check.zig");
const info = @import("info.zig");
const clip = @import("clip.zig");
const format = @import("format.zig");
const channels = @import("channels.zig");
const converter = @import("converter.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Agg = c.GstAudioAggregator;
const AggClass = c.GstAudioAggregatorClass;
const PadClass = c.GstAudioAggregatorPadClass;
const CPadClass = c.GstAudioAggregatorConvertPadClass;
const CAggPad = c.GstAggregatorPad;
const CPadPtr = ?*c.GstAudioAggregatorPad;

const AggPad = extern struct {
    parent: el.Pad,
    segment: c.GstSegment,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const Pad = extern struct {
    parent: AggPad,
    info: c.GstAudioInfo,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};

const CPad = extern struct {
    parent: Pad,
    priv: c.gpointer,
    reserved: [4]c.gpointer,
};
const Buffer = c.GstBuffer;
const NONE = el.NONE;
const U64NONE: u64 = std.math.maxInt(u64);
const SEC: u64 = c.GST_SECOND;
const PATH = "../gst-libs/gst/audio/gstaudioaggregator.c";

const PadPrivate = struct {
    buffer: [*c]Buffer,
    position: c.guint,
    size: c.guint,
    output_offset: u64,
    next_offset: u64,
    discont_time: u64,
    new_segment: bool,
    processed: u64,
    dropped: u64,
    qos_messages: c.gboolean,
};

const CPadPrivate = struct {
    converter: ?*c.GstAudioConverter,
    config: ?*c.GstStructure,
    config_changed: bool,
};

const Private = struct {
    mutex: c.GMutex,
    alignment_threshold: u64,
    discont_wait: u64,
    duration_n: c.gint,
    duration_d: c.gint,
    samples_per_buffer: c.guint,
    error_per_buffer: c.guint,
    accumulated_error: c.guint,
    current_blocksize: c.guint,
    current_buffer: [*c]Buffer,
    offset: i64,
    selected_samples_info: ?*c.GstStructure,
    messages: c.GQueue,
};

var pad_once: gtype.Once = .{};
var pad_offset: c.gint = 0;
var pad_parent: ?*c.GObjectClass = null;
var cpad_once: gtype.Once = .{};
var cpad_offset: c.gint = 0;
var cpad_parent: ?*c.GObjectClass = null;
var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GstAggregatorClass = null;

fn padOf(p: anytype) [*c]Pad {
    return @ptrCast(@alignCast(p));
}

fn segOf(p: anytype) *c.GstSegment {
    return &@as([*c]AggPad, @ptrCast(@alignCast(p))).*.segment;
}

fn ppriv(p: anytype) *PadPrivate {
    return @ptrCast(@alignCast(padOf(p).*.priv));
}

fn cpriv(p: anytype) *CPadPrivate {
    return @ptrCast(@alignCast(@as([*c]CPad, @ptrCast(@alignCast(p))).*.priv));
}

fn padClass(p: anytype) *PadClass {
    return gtype.classPeek(PadClass, p);
}

fn of(p: anytype) [*c]Agg {
    return @ptrCast(@alignCast(p));
}

fn priv(a: anytype) *Private {
    return @ptrCast(@alignCast(of(a).*.priv));
}

fn base(a: anytype) [*c]c.GstAggregator {
    return @ptrCast(@alignCast(a));
}

fn srcPad(a: anytype) [*c]Pad {
    return padOf(base(a).*.srcpad);
}

fn srcSegment(a: anytype) *c.GstSegment {
    return segOf(base(a).*.srcpad);
}

fn aggLock(a: anytype) void {
    c.g_mutex_lock(&priv(a).mutex);
}

fn aggUnlock(a: anytype) void {
    c.g_mutex_unlock(&priv(a).mutex);
}

fn infoValid(i: *const c.GstAudioInfo) bool {
    return i.finfo != null and i.rate > 0 and i.channels > 0 and i.bpf > 0;
}

fn infoFormat(i: *const c.GstAudioInfo) c.GstAudioFormat {
    return if (i.finfo != null) i.finfo.*.format else c.GST_AUDIO_FORMAT_UNKNOWN;
}

fn padFinalize(o: [*c]c.GObject) callconv(.c) void {
    _ = c.gst_buffer_replace(&ppriv(o).buffer, null);
    pad_parent.?.finalize.?(o);
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 163);
    el.lock(o);
    c.g_value_set_boolean(v, ppriv(o).qos_messages);
    el.unlock(o);
}

fn padSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 181);
    el.lock(o);
    ppriv(o).qos_messages = c.g_value_get_boolean(v);
    el.unlock(o);
}

fn resetQos(p: [*c]Pad) void {
    ppriv(p).dropped = 0;
    ppriv(p).processed = 0;
}

fn padFlush(ap: ?*CAggPad, _: [*c]c.GstAggregator) callconv(.c) c.GstFlowReturn {
    const p = padOf(ap);
    const r = ppriv(p);
    el.lock(ap);
    r.position = 0;
    r.size = 0;
    r.output_offset = U64NONE;
    r.next_offset = U64NONE;
    r.discont_time = NONE;
    _ = c.gst_buffer_replace(&r.buffer, null);
    resetQos(p);
    el.unlock(ap);
    return c.GST_FLOW_OK;
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    pad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (pad_offset != 0) c.g_type_class_adjust_private_offset(k, &pad_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSetProperty;
    oc.get_property = padGetProperty;
    oc.finalize = padFinalize;
    @as(*c.GstAggregatorPadClass, @ptrCast(@alignCast(k))).flush = padFlush;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boolean("qos-messages", "Quality of Service Messages", "Emit QoS messages when dropping buffers", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = padOf(inst);
    p.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, pad_offset))));
    const r = ppriv(p);
    r.* = std.mem.zeroes(PadPrivate);
    info.gst_audio_info_init(&p.*.info);
    r.output_offset = U64NONE;
    r.next_offset = U64NONE;
    r.discont_time = NONE;
}

pub export fn gst_audio_aggregator_pad_get_type() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_aggregator_pad_get_type, "GstAudioAggregatorPad", PadClass, Pad, padClassInit, padInit, 0);
            pad_offset = c.g_type_add_instance_private(t, @sizeOf(PadPrivate));
            return t;
        }
    }.f);
}

fn updateConverter(p: [*c]CPad, in_info: [*c]c.GstAudioInfo, out_info: [*c]c.GstAudioInfo) bool {
    const r = cpriv(p);
    if (!r.config_changed) return true;
    if (r.converter) |cv| converter.gst_audio_converter_free(cv);
    r.converter = null;
    if (in_info.*.finfo.*.format == c.GST_AUDIO_FORMAT_UNKNOWN) return false;
    const cv = converter.gst_audio_converter_new(c.GST_AUDIO_CONVERTER_FLAG_NONE, in_info, out_info, if (r.config) |cfg| c.gst_structure_copy(cfg) else null) orelse return false;
    r.config_changed = false;
    if (converter.gst_audio_converter_is_passthrough(cv) == 0) r.converter = cv else converter.gst_audio_converter_free(cv);
    return true;
}

fn updateConversionInfo(p: CPadPtr) callconv(.c) void {
    cpriv(p).config_changed = true;
}

fn convertBuffer(p: CPadPtr, in_info: [*c]c.GstAudioInfo, out_info: [*c]c.GstAudioInfo, input: [*c]Buffer) callconv(.c) [*c]Buffer {
    const cp: [*c]CPad = @ptrCast(@alignCast(p));
    if (!updateConverter(cp, in_info, out_info)) return null;
    const cv = cpriv(cp).converter orelse return @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(input))));
    const insize: c.gint = @intCast(c.gst_buffer_get_size(input));
    const insamples: c.gsize = @intCast(@divTrunc(insize, in_info.*.bpf));
    const outsamples = converter.gst_audio_converter_get_out_frames(cv, insamples);
    const outsize: c.gint = @intCast(outsamples * @as(c.gsize, @intCast(out_info.*.bpf)));
    const res = c.gst_buffer_new_allocate(null, @intCast(outsize), null);
    _ = c.gst_buffer_copy_into(res, input, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS | c.GST_BUFFER_COPY_META, 0, std.math.maxInt(c.gsize));
    var inmap: c.GstMapInfo = undefined;
    var outmap: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(input, &inmap, c.GST_MAP_READ);
    _ = c.gst_buffer_map(res, &outmap, c.GST_MAP_WRITE);
    _ = converter.gst_audio_converter_samples(cv, c.GST_AUDIO_CONVERTER_FLAG_NONE, @ptrCast(&inmap.data), insamples, @ptrCast(&outmap.data), outsamples);
    c.gst_buffer_unmap(input, &inmap);
    c.gst_buffer_unmap(res, &outmap);
    return res;
}

fn cpadFinalize(o: [*c]c.GObject) callconv(.c) void {
    const r = cpriv(o);
    if (r.converter) |cv| converter.gst_audio_converter_free(cv);
    if (r.config) |cfg| c.gst_structure_free(cfg);
    cpad_parent.?.finalize.?(o);
}

fn cpadGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 396);
    el.lock(o);
    if (cpriv(o).config) |cfg| c.g_value_set_boxed(v, cfg);
    el.unlock(o);
}

fn cpadSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    if (id != 1) return el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 417);
    const r = cpriv(o);
    el.lock(o);
    if (r.config) |cfg| c.gst_structure_free(cfg);
    r.config = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
    r.config_changed = true;
    el.unlock(o);
}

fn cpadClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    cpad_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (cpad_offset != 0) c.g_type_class_adjust_private_offset(k, &cpad_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = cpadSetProperty;
    oc.get_property = cpadGetProperty;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_boxed("converter-config", "Converter configuration", "A GstStructure describing the configuration that should be used when converting this pad's audio buffers", c.gst_structure_get_type(), c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    const pc: *PadClass = @ptrCast(@alignCast(k));
    pc.convert_buffer = convertBuffer;
    pc.update_conversion_info = updateConversionInfo;
    oc.finalize = cpadFinalize;
}

fn cpadInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p: [*c]CPad = @ptrCast(@alignCast(inst));
    p.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, cpad_offset))));
    cpriv(p).* = std.mem.zeroes(CPadPrivate);
}

pub export fn gst_audio_aggregator_convert_pad_get_type() c.GType {
    return cpad_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(gst_audio_aggregator_pad_get_type, "GstAudioAggregatorConvertPad", CPadClass, CPad, cpadClassInit, cpadInit, 0);
            cpad_offset = c.g_type_add_instance_private(t, @sizeOf(CPadPrivate));
            return t;
        }
    }.f);
}

fn convert(a: [*c]Agg, pad: anytype, in_info: [*c]c.GstAudioInfo, out_info: [*c]c.GstAudioInfo, buffer: [*c]Buffer) [*c]Buffer {
    _ = a;
    const f = padClass(pad).convert_buffer orelse {
        c.g_assertion_message_expr(check.DOMAIN, PATH, 564, "gst_audio_aggregator_convert_buffer", "klass->convert_buffer");
        return null;
    };
    return f(@ptrCast(pad), in_info, out_info, buffer);
}

fn translateDuration(a: [*c]Agg, duration: u64) void {
    const r = priv(a);
    r.duration_n = @truncate(@as(i64, @bitCast(duration)));
    r.duration_d = @truncate(@as(i64, @bitCast(SEC)));
    const g = c.gst_util_greatest_common_divisor(r.duration_n, r.duration_d);
    if (g != 0) {
        r.duration_n = @divTrunc(r.duration_n, g);
        r.duration_d = @divTrunc(r.duration_d, g);
    }
}

fn updateSamplesPerBuffer(a: [*c]Agg) bool {
    const r = priv(a);
    const sp = srcPad(a);
    if (sp.*.info.finfo == null or sp.*.info.finfo.*.format == c.GST_AUDIO_FORMAT_UNKNOWN) return false;
    const rate: u64 = @intCast(sp.*.info.rate);
    const n: u64 = @bitCast(@as(i64, r.duration_n));
    const d: u64 = @bitCast(@as(i64, r.duration_d));
    r.samples_per_buffer = @truncate(rate *% n / d);
    if (r.samples_per_buffer == 0) return false;
    r.error_per_buffer = @truncate(rate *% n % d);
    r.accumulated_error = 0;
    return true;
}

fn recalculateLatency(a: [*c]Agg) void {
    const r = priv(a);
    const latency = c.gst_util_uint64_scale_int(SEC, r.duration_n, r.duration_d);
    c.gst_aggregator_set_latency(base(a), latency, latency);
    el.lock(a);
    r.samples_per_buffer = 0;
    el.unlock(a);
}

fn constructed(o: [*c]c.GObject) callconv(.c) void {
    @as(*c.GObjectClass, @ptrCast(parent)).constructed.?(o);
    translateDuration(of(o), 10 * 1000000);
    recalculateLatency(of(o));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const a = of(o);
    _ = c.gst_caps_replace(&a.*.current_caps, null);
    if (priv(a).selected_samples_info) |s| c.gst_structure_free(s);
    priv(a).selected_samples_info = null;
    c.g_mutex_clear(&priv(a).mutex);
    @as(*c.GObjectClass, @ptrCast(parent)).dispose.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const a = of(o);
    const r = priv(a);
    switch (id) {
        1 => {
            translateDuration(a, c.g_value_get_uint64(v));
            c.g_object_notify(o, "output-buffer-duration-fraction");
            recalculateLatency(a);
        },
        2 => r.alignment_threshold = c.g_value_get_uint64(v),
        3 => r.discont_wait = c.g_value_get_uint64(v),
        4 => {
            r.duration_n = c.gst_value_get_fraction_numerator(v);
            r.duration_d = c.gst_value_get_fraction_denominator(v);
            c.g_object_notify(o, "output-buffer-duration");
            recalculateLatency(a);
        },
        5 => c.gst_aggregator_set_ignore_inactive_pads(base(a), c.g_value_get_boolean(v)),
        6 => c.gst_aggregator_set_force_live(base(a), c.g_value_get_boolean(v)),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 838),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, ps: [*c]c.GParamSpec) callconv(.c) void {
    const a = of(o);
    const r = priv(a);
    switch (id) {
        1 => c.g_value_set_uint64(v, c.gst_util_uint64_scale_int(SEC, r.duration_n, r.duration_d)),
        2 => c.g_value_set_uint64(v, r.alignment_threshold),
        3 => c.g_value_set_uint64(v, r.discont_wait),
        4 => c.gst_value_set_fraction(v, r.duration_n, r.duration_d),
        5 => c.g_value_set_boolean(v, c.gst_aggregator_get_ignore_inactive_pads(base(a))),
        6 => c.g_value_set_boolean(v, c.gst_aggregator_get_force_live(base(a))),
        else => el.badPropertyAt(o, id, ps, check.DOMAIN, PATH, 874),
    }
}

fn firstConfigured(a: [*c]Agg) [*c]Pad {
    el.lock(a);
    defer el.unlock(a);
    var l = @as([*c]c.GstElement, @ptrCast(a)).*.sinkpads;
    while (l != null) : (l = l.*.next) {
        const p = padOf(l.*.data);
        if (infoFormat(&p.*.info) != c.GST_AUDIO_FORMAT_UNKNOWN) return @ptrCast(@alignCast(c.gst_object_ref(p)));
    }
    return null;
}

fn sinkGetcaps(pad: ?*c.GstPad, a: [*c]Agg, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const first = firstConfigured(a);
    var templ = c.gst_pad_get_pad_template_caps(pad);
    const down = c.gst_pad_get_allowed_caps(base(a).*.srcpad);
    if (first != null) {
        const fc = info.gst_audio_info_to_caps(&first.*.info);
        const tmp = c.gst_caps_intersect_full(templ, fc, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(fc);
        c.gst_caps_unref(templ);
        templ = tmp;
        c.gst_object_unref(first);
    }
    var caps = if (down != null) c.gst_caps_intersect_full(templ, down, c.GST_CAPS_INTERSECT_FIRST) else c.gst_caps_ref(templ);
    if (filter != null) {
        const tmp = c.gst_caps_intersect_full(caps, filter, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = tmp;
    }
    c.gst_caps_unref(templ);
    if (down != null) c.gst_caps_unref(down);
    return caps;
}

fn convertSinkGetcaps(pad: ?*c.GstPad, a: [*c]Agg, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const first = firstConfigured(a);
    var templ = c.gst_pad_get_pad_template_caps(pad);
    const down = c.gst_pad_get_allowed_caps(base(a).*.srcpad);
    if (first != null) {
        templ = c.gst_caps_make_writable(templ);
        c.gst_caps_set_simple_static_str(templ, "rate", c.G_TYPE_INT, first.*.info.rate, @as(?*anyopaque, null));
        c.gst_object_unref(first);
    }
    var caps: [*c]c.GstCaps = undefined;
    if (down != null) {
        const tmp = c.gst_caps_intersect_full(templ, down, c.GST_CAPS_INTERSECT_FIRST);
        const n = c.gst_caps_get_size(tmp);
        var rates = c.gst_caps_new_empty();
        var i: c.guint = 0;
        while (i < n) : (i += 1) {
            const s = c.gst_caps_get_structure(tmp, i);
            const ns = c.gst_structure_new_id_str_empty(c.gst_structure_get_name_id_str(s));
            c.gst_structure_set_value_static_str(ns, "rate", c.gst_structure_get_value(s, "rate"));
            rates = c.gst_caps_merge_structure(rates, ns);
        }
        c.gst_caps_unref(tmp);
        caps = c.gst_caps_intersect_full(templ, rates, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(rates);
    } else caps = c.gst_caps_ref(templ);
    if (filter != null) {
        const tmp = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(caps);
        caps = tmp;
    }
    c.gst_caps_unref(templ);
    if (down != null) c.gst_caps_unref(down);
    return caps;
}

fn sinkSetcaps(p: [*c]Pad, a: [*c]Agg, caps: [*c]c.GstCaps) c.gboolean {
    const first = firstConfigured(a);
    defer if (first != null) c.gst_object_unref(first);
    var ai: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&ai, caps) == 0) return 0;
    var supports = true;
    if (first == null) {
        const down = c.gst_pad_get_allowed_caps(base(a).*.srcpad);
        if (down != null) {
            const rc = c.gst_caps_new_static_str_simple("audio/x-raw", "rate", c.G_TYPE_INT, ai.rate, @as(?*anyopaque, null));
            c.gst_caps_set_features_simple(rc, c.gst_caps_features_copy(c.gst_caps_features_new_any()));
            supports = c.gst_caps_can_intersect(rc, down) != 0;
            c.gst_caps_unref(rc);
            c.gst_caps_unref(down);
        }
    }
    if (!supports or (first != null and ai.rate != first.*.info.rate)) {
        _ = c.gst_pad_push_event(@ptrCast(p), c.gst_event_new_reconfigure());
        return 0;
    }
    el.lock(p);
    p.*.info = ai;
    if (padClass(p).update_conversion_info) |f| f(@ptrCast(p));
    el.unlock(p);
    return 1;
}

fn updateSrcCaps(ab: [*c]c.GstAggregator, caps: [*c]c.GstCaps, ret: [*c][*c]c.GstCaps) callconv(.c) c.GstFlowReturn {
    const templ = c.gst_pad_get_pad_template_caps(ab.*.srcpad);
    const down = c.gst_pad_peer_query_caps(ab.*.srcpad, templ);
    c.gst_caps_unref(templ);
    ret.* = c.gst_caps_intersect(caps, down);
    if (down != null) c.gst_caps_unref(down);
    return c.GST_FLOW_OK;
}

fn fixateSrcCaps(ab: [*c]c.GstAggregator, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const a = of(ab);
    var first: [*c]Pad = null;
    if (padClass(ab.*.srcpad).convert_buffer != null) first = firstConfigured(a);
    var caps = c.gst_caps_make_writable(caps_in);
    const s = c.gst_caps_get_structure(caps, 0);
    if (first != null) {
        const fc = info.gst_audio_info_to_caps(&first.*.info);
        const s2 = c.gst_caps_get_structure(fc, 0);
        var rate: c.gint = 0;
        var chans: c.gint = 0;
        _ = c.gst_structure_get_int(s2, "rate", &rate);
        _ = c.gst_structure_get_int(s2, "channels", &chans);
        _ = c.gst_structure_fixate_field_string(s, "format", c.gst_structure_get_string(s2, "format"));
        _ = c.gst_structure_fixate_field_string(s, "layout", c.gst_structure_get_string(s2, "layout"));
        _ = c.gst_structure_fixate_field_nearest_int(s, "rate", rate);
        _ = c.gst_structure_fixate_field_nearest_int(s, "channels", chans);
        var n: c.gint = 0;
        _ = c.gst_structure_get_int(s, "channels", &n);
        if (c.gst_structure_has_field(s, "channel-mask") == 0 and n > 2) {
            var mask: u64 = 0;
            if (c.gst_structure_get(s2, "channel-mask", c.gst_bitmask_get_type(), &mask, @as(?*anyopaque, null)) == 0) mask = channels.gst_audio_channel_get_fallback_mask(n);
            c.gst_structure_set_static_str(s, "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
        }
        c.gst_caps_unref(fc);
        c.gst_object_unref(first);
    } else {
        _ = c.gst_structure_fixate_field_nearest_int(s, "rate", 44100);
        _ = c.gst_structure_fixate_field_string(s, "format", "S16LE");
        _ = c.gst_structure_fixate_field_string(s, "layout", "interleaved");
        _ = c.gst_structure_fixate_field_nearest_int(s, "channels", 2);
        var n: c.gint = 0;
        if (c.gst_structure_get_int(s, "channels", &n) != 0 and n > 2) {
            if (c.gst_structure_has_field_typed(s, "channel-mask", c.gst_bitmask_get_type()) == 0) c.gst_structure_set_static_str(s, "channel-mask", c.gst_bitmask_get_type(), @as(u64, 0), @as(?*anyopaque, null));
        }
    }
    if (c.gst_caps_is_fixed(caps) == 0) caps = c.gst_caps_fixate(caps);
    return caps;
}

fn updateConverters(a: [*c]Agg, new_info: [*c]c.GstAudioInfo, old_info: [*c]c.GstAudioInfo) void {
    var l = @as([*c]c.GstElement, @ptrCast(a)).*.sinkpads;
    while (l != null) : (l = l.*.next) {
        const p = padOf(l.*.data);
        if (padClass(p).update_conversion_info) |f| f(@ptrCast(p));
        const r = ppriv(p);
        if (r.buffer != null) {
            const nb = convert(a, p, old_info, new_info, r.buffer);
            _ = c.gst_buffer_replace(&r.buffer, nb);
            if (nb != null) c.gst_mini_object_unref(@ptrCast(nb));
        }
    }
}

fn negotiatedSrcCaps(ab: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const a = of(ab);
    const r = priv(a);
    const sp = srcPad(a);
    var ai: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&ai, caps) == 0) return 0;
    aggLock(a);
    el.lock(a);
    if (info.gst_audio_info_is_equal(&ai, &sp.*.info) == 0) {
        var old = sp.*.info;
        _ = c.gst_caps_replace(&a.*.current_caps, caps);
        if (old.rate != ai.rate) r.offset = -1;
        sp.*.info = ai;
        updateConverters(a, &ai, &old);
        if (padClass(sp).update_conversion_info) |f| f(@ptrCast(sp));
        if (r.current_buffer != null) {
            const conv = convert(a, sp, &old, &ai, r.current_buffer);
            c.gst_mini_object_unref(@ptrCast(r.current_buffer));
            r.current_buffer = conv;
            if (conv == null) {
                el.unlock(a);
                aggUnlock(a);
                return 0;
            }
        }
        r.samples_per_buffer = 0;
    }
    el.unlock(a);
    aggUnlock(a);
    return parent.?.negotiated_src_caps.?(ab, caps);
}

fn srcEvent(ab: [*c]c.GstAggregator, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    switch (e.*.type) {
        c.GST_EVENT_QOS, c.GST_EVENT_NAVIGATION => {
            c.gst_mini_object_unref(@ptrCast(e));
            return 0;
        },
        c.GST_EVENT_SEEK => {
            var rate: f64 = 0;
            var fmt: c.GstFormat = 0;
            var flags: c.GstSeekFlags = 0;
            var st: c.GstSeekType = 0;
            var et: c.GstSeekType = 0;
            var start: i64 = 0;
            var stop: i64 = 0;
            c.gst_event_parse_seek(e, &rate, &fmt, &flags, &st, &start, &et, &stop);
            if (st != c.GST_SEEK_TYPE_NONE and st != c.GST_SEEK_TYPE_SET) return 0;
            if (et != c.GST_SEEK_TYPE_NONE and et != c.GST_SEEK_TYPE_SET) return 0;
            el.lock(ab);
            const dest = srcSegment(ab).format;
            el.unlock(ab);
            if (fmt != dest) return 0;
        },
        else => {},
    }
    return parent.?.src_event.?(ab, e);
}

fn sinkEventPreQueue(ab: [*c]c.GstAggregator, ap: ?*CAggPad, e: [*c]c.GstEvent) callconv(.c) c.GstFlowReturn {
    if (e.*.type == c.GST_EVENT_SEGMENT) {
        var seg: c.GstSegment = undefined;
        c.gst_event_copy_segment(e, &seg);
        if (seg.format != c.GST_FORMAT_TIME) {
            c.gst_mini_object_unref(@ptrCast(e));
            return c.GST_FLOW_ERROR;
        }
    }
    return parent.?.sink_event_pre_queue.?(ab, ap, e);
}

fn sinkEvent(ab: [*c]c.GstAggregator, ap: ?*CAggPad, e_in: [*c]c.GstEvent) callconv(.c) c.gboolean {
    var e = e_in;
    var res = true;
    switch (e.*.type) {
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            el.lock(ab);
            if (seg.*.rate != srcSegment(ab).rate or seg.*.rate < 0.0) {
                res = false;
                c.gst_mini_object_unref(@ptrCast(e));
                e = null;
            } else {
                el.lock(ap);
                ppriv(ap).new_segment = true;
                resetQos(padOf(ap));
                el.unlock(ap);
            }
            el.unlock(ab);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(e, &caps);
            res = sinkSetcaps(padOf(ap), of(ab), caps) != 0;
            c.gst_mini_object_unref(@ptrCast(e));
            e = null;
        },
        else => {},
    }
    if (!res) return 0;
    if (e != null) return parent.?.sink_event.?(ab, ap, e);
    return 1;
}

fn sinkQuery(ab: [*c]c.GstAggregator, ap: ?*CAggPad, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q.*.type != c.GST_QUERY_CAPS) return parent.?.sink_query.?(ab, ap, q);
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    const caps = if (gtype.instanceOf(ap, gst_audio_aggregator_convert_pad_get_type())) convertSinkGetcaps(@ptrCast(ap), of(ab), filter) else sinkGetcaps(@ptrCast(ap), of(ab), filter);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn queryDuration(a: [*c]Agg, q: [*c]c.GstQuery) c.gboolean {
    var fmt: c.GstFormat = 0;
    c.gst_query_parse_duration(q, &fmt, null);
    var max: i64 = -1;
    var res: c.gboolean = 1;
    var done = false;
    var item = std.mem.zeroes(c.GValue);
    const it = c.gst_element_iterate_sink_pads(@ptrCast(a));
    while (!done) {
        switch (c.gst_iterator_next(it, &item)) {
            c.GST_ITERATOR_DONE => done = true,
            c.GST_ITERATOR_OK => {
                const pad: ?*c.GstPad = @ptrCast(@alignCast(c.g_value_get_object(&item)));
                var duration: i64 = 0;
                res &= c.gst_pad_peer_query_duration(pad, fmt, &duration);
                if (res != 0) {
                    if (duration == -1) {
                        max = duration;
                        done = true;
                    } else if (duration > max) max = duration;
                }
                _ = c.g_value_reset(&item);
            },
            c.GST_ITERATOR_RESYNC => {
                max = -1;
                res = 1;
                c.gst_iterator_resync(it);
            },
            else => {
                res = 0;
                done = true;
            },
        }
    }
    c.g_value_unset(&item);
    c.gst_iterator_free(it);
    if (res != 0) c.gst_query_set_duration(q, fmt, max);
    return res;
}

fn srcQuery(ab: [*c]c.GstAggregator, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const a = of(ab);
    switch (q.*.type) {
        c.GST_QUERY_DURATION => return queryDuration(a, q),
        c.GST_QUERY_POSITION => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(q, &fmt, null);
            el.lock(a);
            defer el.unlock(a);
            const seg = srcSegment(a);
            switch (fmt) {
                c.GST_FORMAT_TIME => {
                    c.gst_query_set_position(q, fmt, @bitCast(c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, seg.position)));
                    return 1;
                },
                c.GST_FORMAT_BYTES => {
                    const bpf = srcPad(a).*.info.bpf;
                    if (bpf == 0) return 0;
                    c.gst_query_set_position(q, fmt, priv(a).offset *% bpf);
                    return 1;
                },
                c.GST_FORMAT_DEFAULT => {
                    c.gst_query_set_position(q, fmt, priv(a).offset);
                    return 1;
                },
                else => return 0,
            }
        },
        else => return parent.?.src_query.?(ab, q),
    }
}

pub export fn gst_audio_aggregator_set_sink_caps(_: [*c]Agg, pad_in: CPadPtr, caps: [*c]c.GstCaps) void {
    const pad = padOf(pad_in);
    el.lock(pad);
    const valid = info.gst_audio_info_from_caps(&pad.*.info, caps) != 0;
    if (!valid) c.g_assertion_message_expr(check.DOMAIN, PATH, 1666, "gst_audio_aggregator_set_sink_caps", "valid");
    el.unlock(pad);
}

fn reset(a: [*c]Agg) void {
    const r = priv(a);
    aggLock(a);
    el.lock(a);
    srcSegment(a).position = U64NONE;
    r.offset = -1;
    info.gst_audio_info_init(&srcPad(a).*.info);
    _ = c.gst_caps_replace(&a.*.current_caps, null);
    _ = c.gst_buffer_replace(&r.current_buffer, null);
    r.accumulated_error = 0;
    el.unlock(a);
    aggUnlock(a);
}

fn startAgg(ab: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    reset(of(ab));
    return 1;
}

fn stopAgg(ab: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    reset(of(ab));
    return 1;
}

fn flush(ab: [*c]c.GstAggregator) callconv(.c) c.GstFlowReturn {
    const a = of(ab);
    const r = priv(a);
    aggLock(a);
    el.lock(a);
    srcSegment(a).position = U64NONE;
    r.offset = -1;
    r.accumulated_error = 0;
    _ = c.gst_buffer_replace(&r.current_buffer, null);
    el.unlock(a);
    aggUnlock(a);
    return c.GST_FLOW_OK;
}

fn doClip(_: [*c]c.GstAggregator, bp: ?*CAggPad, buffer: [*c]Buffer) callconv(.c) [*c]Buffer {
    const p = padOf(bp);
    if (!infoValid(&p.*.info)) return buffer;
    el.lock(bp);
    defer el.unlock(bp);
    return clip.gst_audio_buffer_clip(buffer, segOf(bp), p.*.info.rate, p.*.info.bpf);
}

fn enqueueQos(p: [*c]Pad, a: [*c]Agg, samples: u64) u64 {
    const ap: ?*CAggPad = @ptrCast(p);
    const sp = srcPad(a);
    const r = ppriv(p);
    const rate_out: u64 = @intCast(sp.*.info.rate);
    const off = c.gst_util_uint64_scale(SEC, r.position, rate_out);
    const ts = r.buffer.*.pts +% off;
    const running = c.gst_segment_to_running_time(segOf(ap), c.GST_FORMAT_TIME, ts);
    const stream = c.gst_segment_to_stream_time(segOf(ap), c.GST_FORMAT_TIME, ts);
    if (r.qos_messages == 0) return running;
    const rate_in: u64 = @intCast(if (padClass(p).convert_buffer != null) sp.*.info.rate else p.*.info.rate);
    const duration = c.gst_util_uint64_scale(samples, SEC, rate_in);
    const processed = c.gst_util_uint64_scale(r.processed, rate_in, rate_out);
    const dropped = c.gst_util_uint64_scale(r.dropped, rate_out, rate_out);
    const msg = c.gst_message_new_qos(@ptrCast(@alignCast(ap)), 1, running, stream, ts, duration);
    c.gst_message_set_qos_stats(msg, c.GST_FORMAT_DEFAULT, processed, dropped);
    c.g_queue_push_tail(&priv(a).messages, msg);
    return running;
}

fn postMessages(a: [*c]Agg) void {
    const r = priv(a);
    if (c.g_queue_get_length(&r.messages) == 0) return;
    const live = c.gst_aggregator_get_latency(base(a)) != NONE;
    while (true) {
        const msg: [*c]c.GstMessage = @ptrCast(@alignCast(c.g_queue_pop_head(&r.messages)));
        if (msg == null) break;
        if (live) c.gst_structure_set_static_str(c.gst_message_writable_structure(msg), "live", c.G_TYPE_BOOLEAN, @as(c.gboolean, 1), @as(?*anyopaque, null));
        _ = c.gst_element_post_message(@ptrCast(a), msg);
    }
}

fn absdiff(x: u64, y: u64) u64 {
    return if (x > y) x - y else y - x;
}

fn fillBuffer(a: [*c]Agg, p: [*c]Pad) bool {
    const ap: ?*CAggPad = @ptrCast(p);
    const sp = srcPad(a);
    const r = ppriv(p);
    const ar = priv(a);
    const conv = padClass(p).convert_buffer != null;
    const rate: c.gint = if (conv) sp.*.info.rate else p.*.info.rate;
    const bpf: c.gint = if (conv) sp.*.info.bpf else p.*.info.bpf;
    const urate: u64 = @intCast(rate);
    r.position = 0;
    r.size = @intCast(c.gst_buffer_get_size(r.buffer) / @as(usize, @intCast(bpf)));
    if (r.size == 0) {
        if (r.buffer.*.duration == NONE or r.buffer.*.mini_object.flags & c.GST_BUFFER_FLAG_GAP == 0) return false;
        r.size = @truncate(c.gst_util_uint64_scale(r.buffer.*.duration, urate, SEC));
    }
    if (r.buffer.*.pts == NONE) {
        if (r.output_offset == U64NONE) r.output_offset = @bitCast(ar.offset);
        if (r.next_offset == U64NONE) r.next_offset = r.size else r.next_offset +%= r.size;
        return true;
    }
    const start_time = r.buffer.*.pts;
    const end_time = start_time +% c.gst_util_uint64_scale_ceil(r.size, SEC, urate);
    if (start_time < segOf(ap).start) c.g_assertion_message_expr(check.DOMAIN, PATH, 1882, "gst_audio_aggregator_fill_buffer", "start_time >= aggpad->segment.start");
    const start_offset = c.gst_util_uint64_scale(start_time - segOf(ap).start, urate, SEC);
    const end_offset = start_offset + r.size;
    var discont = false;
    const flags = r.buffer.*.mini_object.flags;
    if (flags & c.GST_BUFFER_FLAG_DISCONT != 0 or flags & c.GST_BUFFER_FLAG_RESYNC != 0 or r.new_segment or r.next_offset == U64NONE) {
        discont = true;
        r.new_segment = false;
    } else {
        const dd = absdiff(r.next_offset, start_offset);
        const expected = c.gst_util_uint64_scale(r.next_offset, SEC, urate);
        const max_diff = c.gst_util_uint64_scale_int(ar.alignment_threshold, rate, c.GST_SECOND);
        if (dd >= max_diff) {
            if (ar.discont_wait > 0) {
                if (r.discont_time == NONE) {
                    if (absdiff(expected, start_time) >= ar.discont_wait) discont = true else r.discont_time = expected;
                } else if (absdiff(start_time, r.discont_time) >= ar.discont_wait) {
                    discont = true;
                    r.discont_time = NONE;
                }
            } else discont = true;
        } else if (r.discont_time != NONE) r.discont_time = NONE;
    }
    if (discont) r.next_offset = U64NONE else r.next_offset +%= r.size;
    if (r.output_offset == U64NONE or discont) {
        const seg = srcSegment(a);
        const srt = c.gst_segment_to_running_time(segOf(ap), c.GST_FORMAT_TIME, start_time);
        const ert = c.gst_segment_to_running_time(segOf(ap), c.GST_FORMAT_TIME, end_time);
        var so: u64 = U64NONE;
        var eo: u64 = U64NONE;
        var pos = c.gst_segment_position_from_running_time(seg, c.GST_FORMAT_TIME, srt);
        if (pos != NONE) so = c.gst_util_uint64_scale(pos -% seg.start, urate, SEC);
        pos = c.gst_segment_position_from_running_time(seg, c.GST_FORMAT_TIME, ert);
        if (pos != NONE) eo = c.gst_util_uint64_scale(pos -% seg.start, urate, SEC);
        if (so == U64NONE and eo == U64NONE) {
            r.position = 0;
            r.size = 0;
            return false;
        }
        if (eo == U64NONE) eo = so +% r.size;
        const aoff: u64 = @bitCast(ar.offset);
        if (eo < aoff) {
            r.dropped +%= r.size;
            _ = enqueueQos(p, a, r.size);
            r.position = 0;
            r.size = 0;
            return false;
        }
        if (so == U64NONE or so < aoff or (r.output_offset != U64NONE and so < r.output_offset)) {
            var d: c.guint = undefined;
            if (so == U64NONE and eo < r.size) {
                d = @truncate(r.size -% eo +% aoff);
            } else if (so == U64NONE) {
                so = eo -% r.size;
                d = if (so < aoff) @truncate(aoff -% so) else 0;
            } else if (r.output_offset != U64NONE and so < r.output_offset) {
                d = @truncate(r.output_offset -% so);
            } else d = @truncate(aoff -% so);
            r.dropped +%= @min(d, r.size);
            if (d != 0) _ = enqueueQos(p, a, d);
            r.position +%= d;
            if (so != U64NONE) so +%= d;
            if (r.position >= r.size) {
                r.dropped +%= r.size;
                r.position = 0;
                r.size = 0;
                return false;
            }
        }
        r.output_offset = if (so == U64NONE) aoff else so;
        if (r.next_offset == U64NONE) r.next_offset = end_offset;
    }
    return true;
}

fn mixBuffer(a: [*c]Agg, p: [*c]Pad, inbuf: [*c]Buffer, outbuf: [*c]Buffer, blocksize: c.guint) bool {
    const r = ppriv(p);
    const aoff: u64 = @bitCast(priv(a).offset);
    const out_start: c.guint = if (aoff < r.output_offset) @truncate(r.output_offset - aoff) else 0;
    var overlap = r.size -% r.position;
    if (overlap > blocksize -% out_start) overlap = blocksize -% out_start;
    if (inbuf.*.mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0) {
        r.output_offset +%= r.size -% r.position;
        r.position = r.size;
        _ = c.gst_buffer_replace(&r.buffer, null);
        return false;
    }
    _ = c.gst_mini_object_ref(@ptrCast(inbuf));
    const in_offset = r.position;
    el.unlock(p);
    el.unlock(a);
    const filled = gtype.classPeek(AggClass, a).aggregate_one_buffer.?(a, @ptrCast(p), inbuf, in_offset, outbuf, out_start, overlap);
    el.lock(a);
    el.lock(p);
    const changed = inbuf != r.buffer;
    c.gst_mini_object_unref(@ptrCast(inbuf));
    if (filled != 0) outbuf.*.mini_object.flags &= ~@as(c.guint, c.GST_BUFFER_FLAG_GAP);
    if (changed) return false;
    r.processed +%= overlap;
    r.position +%= overlap;
    r.output_offset +%= overlap;
    if (r.position == r.size) {
        _ = c.gst_buffer_replace(&r.buffer, null);
        return false;
    }
    return true;
}

fn createOutputBuffer(a: [*c]Agg, frames: c.guint) callconv(.c) [*c]Buffer {
    const sp = srcPad(a);
    var allocator: [*c]c.GstAllocator = null;
    var params: c.GstAllocationParams = undefined;
    c.gst_aggregator_get_allocator(base(a), &allocator, &params);
    const outbuf = c.gst_buffer_new_allocate(allocator, frames * @as(c.guint, @intCast(sp.*.info.bpf)), &params);
    if (allocator != null) c.gst_object_unref(allocator);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(outbuf, &map, c.GST_MAP_WRITE);
    format.gst_audio_format_info_fill_silence(sp.*.info.finfo, map.data, map.size);
    c.gst_buffer_unmap(outbuf, &map);
    return outbuf;
}

fn peekNextSample(ab: [*c]c.GstAggregator, ap: ?*CAggPad) callconv(.c) ?*c.GstSample {
    const a = of(ab);
    const r = ppriv(ap);
    const aoff: u64 = @bitCast(priv(a).offset);
    if (r.buffer == null or r.output_offset < aoff or r.output_offset >= aoff +% priv(a).samples_per_buffer) return null;
    const caps = c.gst_pad_get_current_caps(@ptrCast(ap));
    const s = c.gst_structure_new_static_str("GstAudioAggregatorPadNextSampleInfo", "output-offset", c.G_TYPE_UINT64, r.output_offset, "position", c.G_TYPE_UINT, r.position, "size", c.G_TYPE_UINT, r.size, @as(?*anyopaque, null));
    const sample = c.gst_sample_new(r.buffer, caps, segOf(ap), s);
    c.gst_caps_unref(caps);
    return sample;
}

fn syncPad(_: [*c]c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) c.gboolean {
    const t: *u64 = @ptrCast(@alignCast(data));
    if (t.* != NONE) _ = c.gst_object_sync_values(@ptrCast(@alignCast(pad)), t.*);
    return 1;
}

fn notNegotiated(a: [*c]Agg) c.GstFlowReturn {
    aggUnlock(a);
    el.messageAt(a, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Unknown data received, not negotiated"), PATH, "gst_audio_aggregator_aggregate", 2651, null);
    return c.GST_FLOW_NOT_NEGOTIATED;
}

fn nextBlocksize(r: *Private) c.guint {
    var bs = r.samples_per_buffer;
    if (r.error_per_buffer +% r.accumulated_error >= @as(c.guint, @intCast(r.duration_d))) bs += 1;
    r.accumulated_error = (r.accumulated_error +% r.error_per_buffer) % @as(c.guint, @intCast(r.duration_d));
    return bs;
}

fn aggregate(ab: [*c]c.GstAggregator, timeout: c.gboolean) callconv(.c) c.GstFlowReturn {
    const a = of(ab);
    const r = priv(a);
    const element: [*c]c.GstElement = @ptrCast(a);
    const sp = srcPad(a);
    const seg = srcSegment(a);
    var dropped = false;
    var is_eos = c.gst_aggregator_get_force_live(ab) == 0;
    var is_done = true;
    aggLock(a);
    el.lock(a);
    if (r.samples_per_buffer == 0 and !updateSamplesPerBuffer(a)) {
        el.unlock(a);
        return notNegotiated(a);
    }
    if (seg.position == U64NONE) seg.position = if (seg.rate > 0.0) seg.start else seg.stop;
    const rate = sp.*.info.rate;
    const bpf = sp.*.info.bpf;
    if (sp.*.info.finfo.*.format == c.GST_AUDIO_FORMAT_UNKNOWN) {
        if (timeout != 0) {
            const bs = nextBlocksize(r);
            const dur = c.gst_util_uint64_scale(bs, SEC, @intCast(rate));
            if (seg.rate > 0.0) {
                seg.position +%= dur;
            } else if (seg.position > dur) seg.position -= dur else seg.position = 0;
            el.unlock(a);
            aggUnlock(a);
            return c.GST_AGGREGATOR_FLOW_NEED_DATA;
        }
        el.unlock(a);
        return notNegotiated(a);
    }
    const urate: u64 = @intCast(rate);
    if (r.offset == -1) r.offset = @bitCast(c.gst_util_uint64_scale(seg.position -% seg.start, urate, SEC));
    var blocksize: c.guint = undefined;
    if (r.current_buffer == null) {
        blocksize = nextBlocksize(r);
        r.current_blocksize = blocksize;
        el.unlock(a);
        r.current_buffer = gtype.classPeek(AggClass, a).create_output_buffer.?(a, blocksize);
        el.lock(a);
        r.current_buffer.*.mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
    } else blocksize = r.current_blocksize;
    var next_offset: i64 = if (seg.rate > 0.0) r.offset + blocksize else r.offset - blocksize;
    var next_ts: u64 = seg.start +% c.gst_util_uint64_scale(@bitCast(next_offset), SEC, urate);
    const outbuf = r.current_buffer;
    var it = element.*.sinkpads;
    while (it != null) : (it = it.*.next) {
        const p = padOf(it.*.data);
        const ap: ?*CAggPad = @ptrCast(@alignCast(it.*.data));
        const pad_eos = c.gst_aggregator_pad_is_eos(ap) != 0;
        if (c.gst_aggregator_pad_is_inactive(ap) != 0) continue;
        if (!pad_eos) is_eos = false;
        const input = c.gst_aggregator_pad_peek_buffer(ap);
        const pr = ppriv(p);
        el.lock(p);
        if (input == null) {
            if (timeout == 0 and !pad_eos) is_done = false;
            el.unlock(p);
            continue;
        } else if (!infoValid(&p.*.info)) {
            el.unlock(p);
            el.unlock(a);
            return notNegotiated(a);
        }
        if (pr.buffer == null) {
            if (padClass(p).convert_buffer != null) {
                pr.buffer = convert(a, p, &p.*.info, &sp.*.info, input);
                if (pr.buffer == null) {
                    el.unlock(p);
                    el.unlock(a);
                    return notNegotiated(a);
                }
            } else pr.buffer = @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(input))));
            if (!fillBuffer(a, p)) {
                _ = c.gst_buffer_replace(&pr.buffer, null);
                c.gst_mini_object_unref(@ptrCast(input));
                dropped = true;
                el.unlock(p);
                _ = c.gst_aggregator_pad_drop_buffer(ap);
                continue;
            }
        }
        c.gst_mini_object_unref(@ptrCast(input));
        if (pr.buffer == null and !dropped and pad_eos) {
            el.unlock(p);
            continue;
        }
        const aoff: u64 = @bitCast(r.offset);
        if (pr.output_offset < aoff) {
            var d: u64 = aoff - pr.output_offset;
            if (pr.position +% d > pr.size) d = pr.size -% pr.position;
            pr.dropped +%= d;
            if (d != 0) _ = enqueueQos(p, a, d);
            pr.position +%= @truncate(d);
            pr.output_offset +%= d;
            if (pr.position == pr.size) {
                _ = c.gst_buffer_replace(&pr.buffer, null);
                dropped = true;
                el.unlock(p);
                _ = c.gst_aggregator_pad_drop_buffer(ap);
                continue;
            }
        }
        el.unlock(p);
    }
    el.unlock(a);
    postMessages(a);
    c.gst_structure_set_static_str(r.selected_samples_info, "offset", c.G_TYPE_UINT64, r.offset, "frames", c.G_TYPE_UINT, blocksize, @as(?*anyopaque, null));
    c.gst_aggregator_selected_samples(ab, seg.position, NONE, next_ts -% seg.position, r.selected_samples_info);
    var stream_time: u64 = c.gst_segment_to_stream_time(seg, c.GST_FORMAT_TIME, if (seg.rate > 0.0) seg.position else next_ts);
    _ = c.gst_element_foreach_sink_pad(element, syncPad, &stream_time);
    el.lock(a);
    const n: usize = element.*.numsinkpads;
    var pads: [64]?*c.GstPad = undefined;
    var heap: ?[*]?*c.GstPad = null;
    const list: [*]?*c.GstPad = if (n <= pads.len) &pads else blk: {
        heap = @ptrCast(@alignCast(c.g_malloc(n * @sizeOf(?*c.GstPad))));
        break :blk heap.?;
    };
    it = element.*.sinkpads;
    var i: usize = 0;
    while (it != null) : (it = it.*.next) {
        list[i] = @ptrCast(@alignCast(c.gst_object_ref(it.*.data)));
        i += 1;
    }
    i = 0;
    while (i < n) : (i += 1) {
        const p = padOf(list[i]);
        const ap: ?*CAggPad = @ptrCast(@alignCast(list[i]));
        if (c.gst_aggregator_pad_is_inactive(ap) != 0) continue;
        el.lock(p);
        const pr = ppriv(p);
        const aoff: u64 = @bitCast(r.offset);
        if (pr.buffer != null and pr.output_offset >= aoff and pr.output_offset < aoff +% blocksize) {
            const drop = !mixBuffer(a, p, pr.buffer, outbuf, blocksize);
            if (pr.output_offset < @as(u64, @bitCast(next_offset))) is_done = false;
            if (drop) {
                el.unlock(p);
                _ = c.gst_aggregator_pad_drop_buffer(ap);
                continue;
            }
        }
        el.unlock(p);
    }
    el.unlock(a);
    i = 0;
    while (i < n) : (i += 1) c.gst_object_unref(list[i]);
    if (heap) |h| c.g_free(@ptrCast(h));
    if (dropped or (!is_done and !is_eos)) {
        aggUnlock(a);
        return c.GST_AGGREGATOR_FLOW_NEED_DATA;
    }
    if (is_eos) {
        var max_offset: i64 = 0;
        el.lock(a);
        it = element.*.sinkpads;
        while (it != null) : (it = it.*.next) {
            if (c.gst_aggregator_pad_is_inactive(@ptrCast(@alignCast(it.*.data))) != 0) continue;
            max_offset = @max(max_offset, @as(i64, @bitCast(ppriv(it.*.data).output_offset)));
        }
        el.unlock(a);
        if (r.offset == max_offset) {
            _ = c.gst_buffer_replace(&r.current_buffer, null);
            aggUnlock(a);
            return c.GST_FLOW_EOS;
        }
        if (max_offset <= next_offset) {
            next_offset = max_offset;
            next_ts = seg.start +% c.gst_util_uint64_scale(@bitCast(next_offset), SEC, urate);
            if (next_offset > r.offset) c.gst_buffer_resize(outbuf, 0, (next_offset - r.offset) * bpf);
        }
    }
    el.lock(a);
    if (seg.rate > 0.0) {
        outbuf.*.pts = seg.position;
        outbuf.*.offset = @bitCast(r.offset);
        outbuf.*.offset_end = @bitCast(next_offset);
        outbuf.*.duration = next_ts -% seg.position;
    } else {
        outbuf.*.pts = next_ts;
        outbuf.*.offset = @bitCast(next_offset);
        outbuf.*.offset_end = @bitCast(r.offset);
        outbuf.*.duration = seg.position -% next_ts;
    }
    el.unlock(a);
    aggUnlock(a);
    const ret = c.gst_aggregator_finish_buffer(ab, outbuf);
    r.current_buffer = null;
    aggLock(a);
    el.lock(a);
    r.offset = next_offset;
    seg.position = next_ts;
    if (timeout != 0) {
        it = element.*.sinkpads;
        while (it != null) : (it = it.*.next) {
            el.lock(it.*.data);
            const pr = ppriv(it.*.data);
            if (pr.output_offset < @as(u64, @bitCast(r.offset))) pr.output_offset = U64NONE;
            el.unlock(it.*.data);
        }
    }
    el.unlock(a);
    aggUnlock(a);
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.constructed = constructed;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.dispose = dispose;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.src_event = srcEvent;
    ac.sink_event = sinkEvent;
    ac.sink_event_pre_queue = sinkEventPreQueue;
    ac.src_query = srcQuery;
    ac.sink_query = sinkQuery;
    ac.start = startAgg;
    ac.stop = stopAgg;
    ac.flush = flush;
    ac.aggregate = aggregate;
    ac.clip = doClip;
    ac.get_next_time = c.gst_aggregator_simple_get_next_time;
    ac.update_src_caps = updateSrcCaps;
    ac.fixate_src_caps = fixateSrcCaps;
    ac.negotiated_src_caps = negotiatedSrcCaps;
    ac.peek_next_sample = peekNextSample;
    @as(*AggClass, @ptrCast(@alignCast(k))).create_output_buffer = createOutputBuffer;
    _ = c._gst_debug_category_new("audioaggregator", c.GST_DEBUG_FG_MAGENTA, "GstAudioAggregator");
    const F = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(oc, 1, c.g_param_spec_uint64("output-buffer-duration", "Output Buffer Duration", "Output block size in nanoseconds", 1, std.math.maxInt(u64), 10 * 1000000, F));
    c.g_object_class_install_property(oc, 4, c.gst_param_spec_fraction("output-buffer-duration-fraction", "Output buffer duration fraction", "Output block size in nanoseconds, expressed as a fraction", 1, std.math.maxInt(c.gint), std.math.maxInt(c.gint), 1, 1, 100, F | c.GST_PARAM_MUTABLE_READY));
    c.g_object_class_install_property(oc, 2, c.g_param_spec_uint64("alignment-threshold", "Alignment Threshold", "Timestamp alignment threshold in nanoseconds", 0, std.math.maxInt(u64) - 1, 40 * 1000000, F));
    c.g_object_class_install_property(oc, 3, c.g_param_spec_uint64("discont-wait", "Discont Wait", "Window of time in nanoseconds to wait before creating a discontinuity", 0, std.math.maxInt(u64) - 1, SEC, F | c.GST_PARAM_MUTABLE_PLAYING));
    c.g_object_class_install_property(oc, 5, c.g_param_spec_boolean("ignore-inactive-pads", "Ignore inactive pads", "Avoid timing out waiting for inactive pads", 0, F));
    c.g_object_class_install_property(oc, 6, c.g_param_spec_boolean("force-live", "Force live", "Always operate in live mode and aggregate on timeout regardless of whether any live sources are linked upstream", 0, F | c.G_PARAM_CONSTRUCT_ONLY));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a = of(inst);
    a.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    const r = priv(a);
    r.* = std.mem.zeroes(Private);
    c.g_mutex_init(&r.mutex);
    r.alignment_threshold = 40 * 1000000;
    r.discont_wait = SEC;
    a.*.current_caps = null;
    r.selected_samples_info = c.gst_structure_new_static_str_empty("GstAudioAggregatorSelectedSamplesInfo");
    c.g_queue_init(&r.messages);
}

pub export fn gst_audio_aggregator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_aggregator_get_type, "GstAudioAggregator", AggClass, Agg, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}
