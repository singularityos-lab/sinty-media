const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/audioresample/gstaudioresample.c";
const NONE = cm.CLOCK_NONE;
const SEC: u64 = 1_000_000_000;
const CAPS = "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved, non-interleaved }";

const PROP_QUALITY = 1;
const PROP_RESAMPLE_METHOD = 2;
const PROP_SINC_FILTER_MODE = 3;
const PROP_SINC_FILTER_AUTO_THRESHOLD = 4;
const PROP_SINC_FILTER_INTERPOLATION = 5;

const Self = extern struct {
    parent: c.GstBaseTransform,
    need_discont: c.gboolean,
    t0: u64,
    in_offset0: u64,
    out_offset0: u64,
    samples_in: u64,
    samples_out: u64,
    num_gap_samples: u64,
    num_nongap_samples: u64,
    method: c.gint,
    quality: c.gint,
    sinc_filter_mode: c.gint,
    sinc_filter_auto_threshold: u32,
    sinc_filter_interpolation: c.gint,
    in: c.GstAudioInfo,
    out: c.GstAudioInfo,
    converter: ?*c.GstAudioConverter,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;
var audio_tag: c.GQuark = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn infoValid(i: *const c.GstAudioInfo) bool {
    return i.finfo != null and i.rate > 0 and i.channels > 0 and i.bpf > 0;
}

fn latency(r: *Self) c.gsize {
    return c.gst_audio_converter_get_max_latency(r.converter);
}

fn resetCounters(r: *Self) void {
    r.num_gap_samples = 0;
    r.num_nongap_samples = 0;
    r.t0 = NONE;
    r.in_offset0 = NONE;
    r.out_offset0 = NONE;
    r.samples_in = 0;
    r.samples_out = 0;
}

fn start(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const r = me(bt);
    r.need_discont = 1;
    resetCounters(r);
    return 1;
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const r = me(bt);
    if (r.converter) |cv| c.gst_audio_converter_free(cv);
    r.converter = null;
    return 1;
}

fn unitSize(_: [*c]c.GstBaseTransform, caps: [*c]c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return 0;
    size[0] = @intCast(info.bpf);
    return 1;
}

fn isIntRange(v: [*c]const c.GValue) bool {
    return v[0].g_type == c.gst_int_range_get_type();
}

fn transformCaps(_: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var res = c.gst_caps_new_empty();
    const n = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        var s = c.gst_caps_get_structure(caps, i);
        if (i > 0 and c.gst_caps_is_subset_structure(res, s) != 0) continue;
        s = c.gst_structure_copy(s);
        const v = c.gst_structure_get_value(s, "rate");
        if (v != null and !isIntRange(v)) c.gst_caps_append_structure(res, c.gst_structure_copy(s));
        c.gst_structure_set_static_str(s, "rate", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(?*anyopaque, null));
        c.gst_caps_append_structure(res, s);
    }
    if (filter != null) {
        const x = c.gst_caps_intersect_full(filter, res, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_mini_object_unref(@ptrCast(res));
        res = x;
    }
    return res;
}

fn fixateCaps(_: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, other_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var rate: c.gint = 0;
    if (c.gst_structure_get_int(c.gst_caps_get_structure(caps, 0), "rate", &rate) == 0) return other_in;
    var other = c.gst_caps_truncate(other_in);
    other = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(other))));
    _ = c.gst_structure_fixate_field_nearest_int(c.gst_caps_get_structure(other, 0), "rate", rate);
    return c.gst_caps_fixate(other);
}

fn makeOptions(r: *Self, in: ?*c.GstAudioInfo, out: ?*c.GstAudioInfo) ?*c.GstStructure {
    const o = c.gst_structure_new_static_str_empty("resampler-options");
    if (in != null and out != null) c.gst_audio_resampler_options_set_quality(@bitCast(r.method), @intCast(r.quality), in.?.rate, out.?.rate, o);
    c.gst_structure_set_static_str(o, c.GST_AUDIO_CONVERTER_OPT_RESAMPLER_METHOD, c.gst_audio_resampler_method_get_type(), r.method, c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE, c.gst_audio_resampler_filter_mode_get_type(), r.sinc_filter_mode, c.GST_AUDIO_RESAMPLER_OPT_FILTER_MODE_THRESHOLD, c.G_TYPE_UINT, r.sinc_filter_auto_threshold, c.GST_AUDIO_RESAMPLER_OPT_FILTER_INTERPOLATION, c.gst_audio_resampler_filter_interpolation_get_type(), r.sinc_filter_interpolation, @as(?*anyopaque, null));
    return o;
}

fn updateState(r: *Self, in: ?*c.GstAudioInfo, out: ?*c.GstAudioInfo) bool {
    if (r.converter == null and in == null and out == null) return true;
    const options = makeOptions(r, in, out);
    const old: ?c.gsize = if (r.converter != null) latency(r) else null;
    if (in) |i| {
        if (r.converter != null and (i.finfo != r.in.finfo or i.channels != r.in.channels or i.layout != r.in.layout)) {
            c.gst_audio_converter_free(r.converter);
            r.converter = null;
        }
    }
    if (r.converter == null) {
        r.converter = c.gst_audio_converter_new(c.GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE, in, out, options);
        if (r.converter == null) return false;
    } else if (in != null and out != null) {
        if (c.gst_audio_converter_update_config(r.converter, in.?.rate, out.?.rate, options) == 0) return false;
    } else c.gst_structure_free(options);
    if (old) |o| {
        if (o != latency(r)) _ = c.gst_element_post_message(@ptrCast(@alignCast(r)), c.gst_message_new_latency(cm.obj(r)));
    }
    return true;
}

fn resetState(r: *Self) void {
    if (r.converter) |cv| c.gst_audio_converter_reset(cv);
}

fn transformSize(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, _: [*c]c.GstCaps, size: c.gsize, _: [*c]c.GstCaps, other: [*c]c.gsize) callconv(.c) c.gboolean {
    const r = me(bt);
    const bpf: c.gsize = @intCast(r.in.bpf);
    const frames = size / bpf;
    other[0] = bpf * (if (dir == c.GST_PAD_SINK) c.gst_audio_converter_get_out_frames(r.converter, frames) else c.gst_audio_converter_get_in_frames(r.converter, frames));
    return 1;
}

fn setCaps(bt: [*c]c.GstBaseTransform, incaps: [*c]c.GstCaps, outcaps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const r = me(bt);
    var in: c.GstAudioInfo = undefined;
    var out: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&in, incaps) == 0 or c.gst_audio_info_from_caps(&out, outcaps) == 0) return 0;
    if (c.gst_audio_info_is_equal(&in, &r.in) == 0 or c.gst_audio_info_is_equal(&out, &r.out) == 0) {
        if (r.converter != null) pushDrain(r, @intCast(latency(r)));
        resetState(r);
        resetCounters(r);
        r.need_discont = 1;
    }
    _ = updateState(r, &in, &out);
    r.in = in;
    r.out = out;
    return 1;
}

fn drainBuffer(r: *Self, history: c.guint, size_bpf: c.gint) ?struct { [*c]c.GstBuffer, c.gsize } {
    const out_len = c.gst_audio_converter_get_out_frames(r.converter, history);
    if (out_len == 0) return null;
    const b = c.gst_buffer_new_allocate(null, out_len * @as(c.gsize, @intCast(size_bpf)), null);
    if (r.out.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) _ = c.gst_buffer_add_audio_meta(b, &r.out, out_len, null);
    var ab: c.GstAudioBuffer = undefined;
    _ = c.gst_audio_buffer_map(&ab, &r.out, b, c.GST_MAP_WRITE);
    _ = c.gst_audio_converter_samples(r.converter, 0, null, history, ab.planes, out_len);
    c.gst_audio_buffer_unmap(&ab);
    return .{ b, out_len };
}

fn dumpDrain(r: *Self, history: c.guint) void {
    const d = drainBuffer(r, history, r.out.bpf) orelse return;
    c.gst_buffer_unref(d[0]);
}

fn stamp(r: *Self, b: [*c]c.GstBuffer, out_len: u64) void {
    const x = cm.buf(b);
    if (r.t0 != NONE) {
        const rate: c.gint = r.out.rate;
        x.pts = r.t0 + c.gst_util_uint64_scale_int_round(r.samples_out, SEC, rate);
        x.duration = r.t0 + c.gst_util_uint64_scale_int_round(r.samples_out + out_len, SEC, rate) - x.pts;
    } else {
        x.pts = NONE;
        x.duration = NONE;
    }
    if (r.out_offset0 != NONE) {
        x.offset = r.out_offset0 + r.samples_out;
        x.offset_end = x.offset + out_len;
    } else {
        x.offset = NONE;
        x.offset_end = NONE;
    }
}

fn pushDrain(r: *Self, history: c.guint) void {
    if (r.converter == null) c.g_assertion_message_expr(null, FILE, 598, "gst_audio_resample_push_drain", "resample->converter != NULL");
    if (r.t0 == NONE) return;
    const d = drainBuffer(r, history, r.in.bpf) orelse return;
    stamp(r, d[0], d[1]);
    r.samples_out += d[1];
    r.samples_in += history;
    _ = c.gst_pad_push(trans(r)[0].srcpad, d[0]);
}

fn sinkEvent(bt: [*c]c.GstBaseTransform, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const r = me(bt);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_FLUSH_STOP => {
            resetState(r);
            resetCounters(r);
            r.need_discont = 1;
        },
        c.GST_EVENT_STREAM_START, c.GST_EVENT_SEGMENT, c.GST_EVENT_EOS => {
            if (r.converter != null) pushDrain(r, @intCast(latency(r)));
            resetState(r);
            resetCounters(r);
            r.need_discont = 1;
        },
        else => {},
    }
    return parent.?.sink_event.?(bt, ev);
}

fn checkDiscont(r: *Self, b: [*c]c.GstBuffer) bool {
    const x = cm.buf(b);
    if (x.mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) return true;
    if (x.pts == NONE or r.t0 == NONE) return false;
    const off = c.gst_util_uint64_scale_int_round(x.pts -% r.t0, r.in.rate, @intCast(SEC));
    const diff: i64 = @bitCast(off -% r.samples_in);
    const delta: u64 = @abs(diff);
    return delta > @as(u64, @intCast(r.in.rate >> 5));
}

fn process(r: *Self, inbuf: [*c]c.GstBuffer, outbuf: [*c]c.GstBuffer) c.GstFlowReturn {
    const filt: u64 = latency(r) * 2;
    const writable = c.gst_buffer_is_writable(inbuf) != 0 and c.gst_buffer_n_memory(inbuf) == 1 and c.gst_memory_is_writable(c.gst_buffer_peek_memory(inbuf, 0)) != 0;
    var src: c.GstAudioBuffer = undefined;
    var dst: c.GstAudioBuffer = undefined;
    _ = c.gst_audio_buffer_map(&src, &r.in, inbuf, if (writable) c.GST_MAP_READWRITE else c.GST_MAP_READ);
    var in_len: u64 = src.n_samples;
    var out_len: u64 = c.gst_audio_converter_get_out_frames(r.converter, in_len);
    c.gst_buffer_set_size(outbuf, @intCast(out_len * @as(u64, @intCast(r.in.bpf))));
    if (r.out.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) _ = c.gst_buffer_add_audio_meta(outbuf, &r.out, out_len, null);
    _ = c.gst_audio_buffer_map(&dst, &r.out, outbuf, c.GST_MAP_WRITE);
    if (cm.buf(inbuf).mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0) {
        r.num_nongap_samples = 0;
        if (r.num_gap_samples < filt) {
            const zeros: u64 = if (in_len >= filt - r.num_gap_samples) filt - r.num_gap_samples else in_len;
            pushDrain(r, @truncate(zeros));
            in_len -= zeros;
            r.num_gap_samples += zeros;
        }
        const num: c.gint = r.in.rate;
        const den: c.gint = r.out.rate;
        out_len = if (r.samples_in + in_len >= filt / 2) c.gst_util_uint64_scale_int_ceil(r.samples_in + in_len - filt / 2, den, num) -% r.samples_out else 0;
        const stride: u64 = @intCast(if (r.out.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) @divTrunc(r.out.bpf, r.out.channels) else r.out.bpf);
        var i: c.gint = 0;
        while (i < dst.n_planes) : (i += 1) @memset(@as([*]u8, @ptrCast(dst.planes[@intCast(i)]))[0 .. dst.n_samples * stride], 0);
        cm.buf(outbuf).mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
        r.num_gap_samples += in_len;
    } else {
        if (r.num_gap_samples > filt) dumpDrain(r, @truncate((r.num_gap_samples - filt) % @as(u64, @intCast(r.in.rate))));
        r.num_gap_samples = 0;
        if (r.num_nongap_samples < filt) r.num_nongap_samples = @min(r.num_nongap_samples + in_len, filt);
        const flags: c.GstAudioConverterFlags = if (writable) c.GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE else 0;
        _ = c.gst_audio_converter_samples(r.converter, flags, src.planes, in_len, dst.planes, out_len);
    }
    stamp(r, outbuf, out_len);
    r.samples_out += out_len;
    r.samples_in += in_len;
    c.gst_audio_buffer_unmap(&src);
    c.gst_audio_buffer_unmap(&dst);
    return if (out_len * @as(u64, @intCast(r.in.bpf)) == 0) c.GST_BASE_TRANSFORM_FLOW_DROPPED else c.GST_FLOW_OK;
}

fn transform(bt: [*c]c.GstBaseTransform, inbuf: [*c]c.GstBuffer, outbuf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const r = me(bt);
    if (checkDiscont(r, inbuf)) {
        if (r.converter != null) pushDrain(r, @intCast(latency(r)));
        resetState(r);
        r.need_discont = 1;
    }
    if (r.need_discont != 0) {
        r.num_gap_samples = 0;
        r.num_nongap_samples = 0;
        r.samples_in = 0;
        r.samples_out = 0;
        const x = cm.buf(inbuf);
        r.t0 = x.pts;
        if (x.offset != NONE) {
            r.in_offset0 = x.offset;
            r.out_offset0 = c.gst_util_uint64_scale_int_round(r.in_offset0, r.out.rate, r.in.rate);
        } else {
            r.in_offset0 = NONE;
            r.out_offset0 = NONE;
        }
        cm.buf(outbuf).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        r.need_discont = 0;
    }
    return process(r, inbuf, outbuf);
}

fn transformMeta(_: [*c]c.GstBaseTransform, _: [*c]c.GstBuffer, meta: [*c]c.GstMeta, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const api = meta[0].info[0].api;
    const tags = c.gst_meta_api_type_get_tags(api);
    return @intFromBool(tags == null or (c.g_strv_length(@ptrCast(@constCast(tags))) == 1 and c.gst_meta_api_type_has_tag(api, audio_tag) != 0));
}

fn submitInput(bt: [*c]c.GstBaseTransform, discont: c.gboolean, input_in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const r = me(bt);
    var input = input_in;
    if (bt[0].segment.format == c.GST_FORMAT_TIME) {
        if (!infoValid(&r.in)) return c.GST_FLOW_NOT_NEGOTIATED;
        input = c.gst_audio_buffer_clip(input, &bt[0].segment, r.in.rate, r.in.bpf);
        if (input == null) return c.GST_FLOW_OK;
    }
    return parent.?.submit_input_buffer.?(bt, discont, input);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const r = me(par);
    if (cm.queryType(q) != c.GST_QUERY_LATENCY) return c.gst_pad_query_default(pad, par, q);
    const rate = r.in.rate;
    var lat: c.gint = if (r.converter != null) @intCast(latency(r)) else 0;
    if (c.gst_base_transform_is_passthrough(trans(r)) != 0) lat = 0;
    const res = c.gst_pad_peer_query(trans(r)[0].sinkpad, q);
    if (res != 0) {
        var live: c.gboolean = 0;
        var min: u64 = 0;
        var max: u64 = 0;
        c.gst_query_parse_latency(q, &live, &min, &max);
        const add: u64 = if (rate != 0 and lat != 0) c.gst_util_uint64_scale_round(@intCast(lat), SEC, @intCast(rate)) else 0;
        min += add;
        if (max != NONE) max += add;
        c.gst_query_set_latency(q, live, min, max);
    }
    return res;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const r = me(o);
    switch (id) {
        PROP_QUALITY => r.quality = c.g_value_get_int(v),
        PROP_RESAMPLE_METHOD => r.method = c.g_value_get_enum(v),
        PROP_SINC_FILTER_MODE => r.sinc_filter_mode = c.g_value_get_enum(v),
        PROP_SINC_FILTER_AUTO_THRESHOLD => r.sinc_filter_auto_threshold = c.g_value_get_uint(v),
        PROP_SINC_FILTER_INTERPOLATION => r.sinc_filter_interpolation = c.g_value_get_enum(v),
        else => return cm.warnInvalid(FILE, o, id, spec, 1099),
    }
    _ = updateState(r, null, null);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const r = me(o);
    switch (id) {
        PROP_QUALITY => c.g_value_set_int(v, r.quality),
        PROP_RESAMPLE_METHOD => c.g_value_set_enum(v, r.method),
        PROP_SINC_FILTER_MODE => c.g_value_set_enum(v, r.sinc_filter_mode),
        PROP_SINC_FILTER_AUTO_THRESHOLD => c.g_value_set_uint(v, r.sinc_filter_auto_threshold),
        PROP_SINC_FILTER_INTERPOLATION => c.g_value_set_enum(v, r.sinc_filter_interpolation),
        else => cm.warnInvalid(FILE, o, id, spec, 1129),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    c.g_object_class_install_property(oc, PROP_QUALITY, c.g_param_spec_int("quality", "Quality", "Resample quality with 0 being the lowest and 10 being the best", c.GST_AUDIO_RESAMPLER_QUALITY_MIN, c.GST_AUDIO_RESAMPLER_QUALITY_MAX, c.GST_AUDIO_RESAMPLER_QUALITY_DEFAULT, cm.RW | c.G_PARAM_CONSTRUCT));
    c.g_object_class_install_property(oc, PROP_RESAMPLE_METHOD, c.g_param_spec_enum("resample-method", "Resample method to use", "What resample method to use", c.gst_audio_resampler_method_get_type(), c.GST_AUDIO_RESAMPLER_METHOD_KAISER, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINC_FILTER_MODE, c.g_param_spec_enum("sinc-filter-mode", "Sinc filter table mode", "What sinc filter table mode to use", c.gst_audio_resampler_filter_mode_get_type(), c.GST_AUDIO_RESAMPLER_FILTER_MODE_AUTO, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINC_FILTER_AUTO_THRESHOLD, c.g_param_spec_uint("sinc-filter-auto-threshold", "Sinc filter auto mode threshold", "Memory usage threshold to use if sinc filter mode is AUTO, given in bytes", 0, std.math.maxInt(c.guint), 1 * 1048576, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINC_FILTER_INTERPOLATION, c.g_param_spec_enum("sinc-filter-interpolation", "Sinc filter interpolation", "How to interpolate the sinc filter table", c.gst_audio_resampler_filter_interpolation_get_type(), c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Audio resampler", "Filter/Converter/Audio", "Resamples audio", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.start = start;
    tc.stop = stop;
    tc.transform_size = transformSize;
    tc.get_unit_size = unitSize;
    tc.transform_caps = transformCaps;
    tc.fixate_caps = fixateCaps;
    tc.set_caps = setCaps;
    tc.transform = transform;
    tc.sink_event = sinkEvent;
    tc.transform_meta = transformMeta;
    tc.submit_input_buffer = submitInput;
    tc.passthrough_on_same_caps = 1;
    c.gst_type_mark_as_plugin_api(c.gst_audio_resampler_method_get_type(), 0);
    c.gst_type_mark_as_plugin_api(c.gst_audio_resampler_filter_interpolation_get_type(), 0);
    c.gst_type_mark_as_plugin_api(c.gst_audio_resampler_filter_mode_get_type(), 0);
    audio_tag = c.g_quark_from_static_string(c.GST_META_TAG_AUDIO_STR);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const r = me(inst);
    r.method = c.GST_AUDIO_RESAMPLER_METHOD_KAISER;
    r.quality = c.GST_AUDIO_RESAMPLER_QUALITY_DEFAULT;
    r.sinc_filter_mode = c.GST_AUDIO_RESAMPLER_FILTER_MODE_AUTO;
    r.sinc_filter_auto_threshold = 1 * 1048576;
    r.sinc_filter_interpolation = c.GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC;
    c.gst_base_transform_set_gap_aware(trans(r), 1);
    c.gst_pad_set_query_function_full(trans(r)[0].srcpad, srcQuery, null, null);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_base_transform_get_type(), "GstAudioResample", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("audioresample", 0, "audio resampling element");
    return c.gst_element_register(p, "audioresample", c.GST_RANK_PRIMARY, getType()) != 0;
}
