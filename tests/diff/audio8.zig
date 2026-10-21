const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);
const NOPROP = @as([*c]const u8, null);

var setups: u32 = 0;
var fail_setup = false;

fn setup(f: [*c]c.GstAudioFilter, info: [*c]const c.GstAudioInfo) callconv(.c) c.gboolean {
    setups += 1;
    out("  setup rate {d} ch {d} bpf {d} format {s} prior-valid {d}", .{ info.*.rate, info.*.channels, info.*.bpf, c.gst_audio_format_to_string(info.*.finfo.*.format), @intFromBool(f.*.info.finfo != null) });
    return if (fail_setup) 0 else 1;
}

fn transformIp(_: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READWRITE);
    const p: [*]i16 = @ptrCast(@alignCast(map.data));
    for (p[0 .. map.size / 2]) |*v| v.* = -%v.*;
    c.gst_buffer_unmap(b, &map);
    return c.GST_FLOW_OK;
}

fn classInit(kl: c.gpointer, _: c.gpointer) callconv(.c) void {
    const k: *c.GstAudioFilterClass = @ptrCast(@alignCast(kl));
    k.setup = setup;
    const bk: *c.GstBaseTransformClass = @ptrCast(@alignCast(kl));
    bk.transform_ip = transformIp;
    const caps = c.gst_caps_from_string("audio/x-raw,format=S16LE,layout=interleaved,rate=[1,max],channels=[1,8]");
    c.gst_audio_filter_class_add_pad_templates(k, caps);
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(kl)), "Negate", "Filter/Audio", "test", "test");
}

fn filterType() c.GType {
    const S = struct {
        var t: c.GType = 0;
    };
    if (S.t == 0) S.t = c.g_type_register_static_simple(c.gst_audio_filter_get_type(), "TestNegate", @sizeOf(c.GstAudioFilterClass), classInit, @sizeOf(c.GstAudioFilter), null, 0);
    return S.t;
}

fn templates(t: c.GType) void {
    const k: [*c]c.GstElementClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    var l = c.gst_element_class_get_pad_template_list(k);
    while (l != null) : (l = l.*.next) {
        const tp: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        const s = c.gst_caps_to_string(tp.*.caps);
        out("  template {s} dir {d} presence {d} caps {s}", .{ tp.*.name_template, tp.*.direction, tp.*.presence, s });
        c.g_free(s);
    }
}

var cur_info: c.GstAudioInfo = undefined;
var cur_caps: [*c]c.GstCaps = null;

fn push(src: [*c]c.GstElement, pts: u64, frames: usize, ch: usize, base: i16, seg: ?*c.GstSegment) void {
    const b = c.gst_buffer_new_allocate(null, frames * ch * 2, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    const p: [*]i16 = @ptrCast(@alignCast(map.data));
    for (0..frames * ch) |i| p[i] = base +% @as(i16, @intCast(i % 1000));
    c.gst_buffer_unmap(b, &map);
    b.*.pts = pts;
    b.*.duration = c.gst_util_uint64_scale_int(frames, c.GST_SECOND, 8000);
    _ = c.gst_buffer_add_audio_meta(b, &cur_info, frames, null);
    var ret: c.GstFlowReturn = 0;
    if (seg) |sg| {
        const smp = c.gst_sample_new(b, cur_caps, sg, null);
        c.g_signal_emit_by_name(src, "push-sample", smp, &ret);
        c.gst_sample_unref(smp);
    } else c.g_signal_emit_by_name(src, "push-buffer", b, &ret);
    c.gst_buffer_unref(b);
}

fn drain(sink: [*c]c.GstElement, label: []const u8) void {
    while (true) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "try-pull-sample", @as(u64, 200 * c.GST_MSECOND), &sample);
        if (sample == null) break;
        const b = c.gst_sample_get_buffer(sample);
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        const p: [*]const i16 = @ptrCast(@alignCast(map.data));
        var h: u64 = 0xcbf29ce484222325;
        for (map.data[0..map.size]) |x| h = (h ^ x) *% 0x100000001b3;
        const meta: [*c]c.GstAudioMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_meta_api_get_type())));
        out("  {s} pts {d} dur {d} size {d} first {d} hash {x} audiometa {d} samples {d}", .{ label, b.*.pts, b.*.duration, map.size, if (map.size >= 2) p[0] else 0, h, @intFromBool(meta != null), if (meta != null) meta.*.samples else 0 });
        c.gst_buffer_unmap(b, &map);
        c.gst_sample_unref(sample);
    }
}

fn pipeline(elem: [*c]c.GstElement, caps_str: [*c]const u8, ch: usize, label: []const u8) void {
    out("pipeline {s} {s}", .{ label, caps_str });
    const pipe = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make("appsrc", "src");
    const sink = c.gst_element_factory_make("appsink", "sink");
    const caps = c.gst_caps_from_string(caps_str);
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    _ = c.gst_audio_info_from_caps(&cur_info, caps);
    cur_caps = caps;
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), NONE);
    _ = c.gst_bin_add(@ptrCast(pipe), src);
    _ = c.gst_bin_add(@ptrCast(pipe), elem);
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    out("  link {d}", .{@intFromBool(c.gst_element_link_many(src, elem, sink, NONE) != 0)});
    out("  playing {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_PLAYING)});
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.start = 30 * c.GST_MSECOND;
    seg.stop = 170 * c.GST_MSECOND;
    var i: usize = 0;
    while (i < 5) : (i += 1) push(src, i * 50 * c.GST_MSECOND, 400, ch, @intCast(i * 7), if (i == 0) &seg else null);
    var ret: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &ret);
    drain(sink, label);
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    c.gst_caps_unref(cur_caps);
    const f: [*c]c.GstAudioFilter = @ptrCast(@alignCast(elem));
    if (c.g_type_is_a(@as(*c.GTypeInstance, @ptrCast(@alignCast(elem))).g_class.*.g_type, c.gst_audio_filter_get_type()) != 0) out("  info after null valid {d} rate {d}", .{ @intFromBool(f.*.info.finfo != null), f.*.info.rate });
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.gst_init(null, null);
    const t = c.gst_audio_filter_get_type();
    out("type {s} abstract {d} parent {s}", .{ c.g_type_name(t), @intFromBool(c.g_type_test_flags(t, c.G_TYPE_FLAG_ABSTRACT) != 0), c.g_type_name(c.g_type_parent(t)) });
    templates(filterType());
    const caps = c.gst_caps_from_string("audio/x-raw");
    c.gst_audio_filter_class_add_pad_templates(null, caps);
    c.gst_audio_filter_class_add_pad_templates(@ptrCast(@alignCast(c.g_type_class_ref(c.gst_element_get_type()))), caps);
    c.gst_audio_filter_class_add_pad_templates(@ptrCast(@alignCast(c.g_type_class_ref(filterType()))), null);
    c.gst_caps_unref(caps);
    const neg: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(filterType(), "name", "neg", NONE)));
    const nf: [*c]c.GstAudioFilter = @ptrCast(@alignCast(neg));
    out("fresh info valid {d} rate {d} ch {d}", .{ @intFromBool(nf.*.info.finfo != null), nf.*.info.rate, nf.*.info.channels });
    pipeline(neg, "audio/x-raw,format=S16LE,layout=interleaved,rate=8000,channels=2", 2, "negate");
    out("setups {d}", .{setups});
    fail_setup = true;
    const neg2: [*c]c.GstElement = @ptrCast(@alignCast(c.g_object_new(filterType(), "name", "neg2", NONE)));
    pipeline(neg2, "audio/x-raw,format=S16LE,layout=interleaved,rate=8000,channels=1", 1, "failing");
    const vol = c.gst_element_factory_make("volume", "vol");
    if (vol == null) {
        out("no volume element", .{});
        return;
    }
    out("volume is audiofilter {d}", .{c.g_type_is_a(@as(*c.GTypeInstance, @ptrCast(@alignCast(vol))).g_class.*.g_type, c.gst_audio_filter_get_type())});
    c.g_object_set(vol, "volume", @as(f64, 0.5), NONE);
    pipeline(vol, "audio/x-raw,format=S16LE,layout=interleaved,rate=8000,channels=2", 2, "volume");
    const vol2 = c.gst_element_factory_make("volume", "vol2");
    c.g_object_set(vol2, "volume", @as(f64, 1.7), NONE);
    pipeline(vol2, "audio/x-raw,format=F32LE,layout=interleaved,rate=8000,channels=1", 1, "volume-f32");
}
