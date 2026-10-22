const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const NONE = @as(?*anyopaque, null);

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

var setups: u32 = 0;
var render_fail = false;

fn setup(s: [*c]c.GstAudioVisualizer) callconv(.c) c.gboolean {
    setups += 1;
    out("  setup req_spf={d} {d}x{d} rate={d} ch={d}", .{ s[0].req_spf, s[0].vinfo.width, s[0].vinfo.height, s[0].ainfo.rate, s[0].ainfo.channels });
    if (setups == 1) s[0].req_spf = s[0].req_spf / 2;
    return 1;
}

fn render(s: [*c]c.GstAudioVisualizer, audio: [*c]c.GstBuffer, frame: [*c]c.GstVideoFrame) callconv(.c) c.gboolean {
    if (render_fail) return 0;
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(audio, &mi, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(audio, &mi);
    const d: [*]u8 = @ptrCast(frame[0].data[0]);
    const stride: usize = @intCast(frame[0].info.stride[0]);
    const w: usize = @intCast(frame[0].info.width);
    const h: usize = @intCast(frame[0].info.height);
    const n = mi.size / 2;
    for (0..n) |i| {
        const v = std.mem.readInt(i16, mi.data[i * 2 ..][0..2], .little);
        const x = i % w;
        const y = @as(usize, @intCast(@as(i32, v) + 32768)) * h / 65536;
        const p = d + y * stride + x * 4;
        p[0] = @truncate(i * 37);
        p[1] = @truncate(@as(u32, @bitCast(@as(i32, v))) >> 4);
        p[2] = 200;
        p[3] = 255;
    }
    _ = s;
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const vc: *c.GstAudioVisualizerClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, c.gst_caps_from_string("audio/x-raw, format=S16LE, layout=interleaved, rate=(int)[1,2147483647], channels=(int)[1,2]")));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, c.gst_caps_from_string("video/x-raw, format=BGRx, width=(int)[1,2147483647], height=(int)[1,2147483647], framerate=(fraction)[0/1,2147483647/1]")));
    c.gst_element_class_set_static_metadata(ec, "t", "Visualization", "t", "t");
    vc.setup = setup;
    vc.render = render;
}

fn crc(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

fn audioBuf(i: usize, samples: usize) [*c]c.GstBuffer {
    const b = c.gst_buffer_new_allocate(null, samples * 2, null);
    var mi: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &mi, c.GST_MAP_WRITE);
    for (0..samples) |k| {
        const ph: f64 = @as(f64, @floatFromInt(i * samples + k)) * 0.07;
        const v: i16 = @intFromFloat(@sin(ph) * 20000.0);
        std.mem.writeInt(i16, mi.data[k * 2 ..][0..2], v, .little);
    }
    c.gst_buffer_unmap(b, &mi);
    b[0].pts = i * 100 * c.GST_MSECOND;
    b[0].duration = 100 * c.GST_MSECOND;
    return b;
}

fn drain(sink: ?*c.GstElement, label: []const u8) void {
    var n: usize = 0;
    while (true) {
        var sample: ?*c.GstSample = null;
        c.g_signal_emit_by_name(sink, "try-pull-sample", @as(u64, 2 * c.GST_SECOND), &sample);
        if (sample == null) break;
        const b = c.gst_sample_get_buffer(sample);
        var mi: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &mi, c.GST_MAP_READ);
        if (n == 0) {
            const cs = c.gst_caps_to_string(c.gst_sample_get_caps(sample));
            out("  {s} caps {s}", .{ label, z(cs) });
            c.g_free(cs);
        }
        out("  {s} frame {d} pts {d} dur {d} size {d} crc {x:0>8}", .{ label, n, @as(i64, @bitCast(b[0].pts)), @as(i64, @bitCast(b[0].duration)), mi.size, if (std.mem.eql(u8, label, "plugin")) 0 else crc(mi.data[0..mi.size]) });
        c.gst_buffer_unmap(b, &mi);
        c.gst_sample_unref(sample);
        n += 1;
    }
    out("  {s} total {d}", .{ label, n });
}

fn runScope(t: c.GType, shader: c_int, amount: u32, rate: c_int, ch: c_int, w: c_int, h: c_int, discont: bool) void {
    out("scope shader={d} amount={x} rate={d} ch={d} {d}x{d}", .{ shader, amount, rate, ch, w, h });
    setups = 0;
    const pipe = c.gst_pipeline_new(null);
    const src = c.gst_element_factory_make("appsrc", null);
    const scope: ?*c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, "shader", shader, "shade-amount", amount, NONE)));
    const sink = c.gst_element_factory_make("appsink", null);
    const caps = c.gst_caps_new_simple("audio/x-raw", "format", c.G_TYPE_STRING, "S16LE", "layout", c.G_TYPE_STRING, "interleaved", "rate", c.G_TYPE_INT, rate, "channels", c.G_TYPE_INT, ch, NONE);
    c.g_object_set(src, "caps", caps, "format", @as(c_int, c.GST_FORMAT_TIME), NONE);
    const vcaps = c.gst_caps_new_simple("video/x-raw", "width", c.G_TYPE_INT, w, "height", c.G_TYPE_INT, h, "framerate", c.gst_fraction_get_type(), @as(c_int, 10), @as(c_int, 1), NONE);
    c.g_object_set(sink, "caps", vcaps, "sync", @as(c.gboolean, 0), NONE);
    c.gst_bin_add_many(@ptrCast(pipe), src, scope, sink, NONE);
    _ = c.gst_element_link_many(src, scope, sink, NONE);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    const per: usize = @intCast(@divTrunc(rate, 10) * ch);
    for (0..6) |i| {
        const b = audioBuf(i, per * 3 / 2);
        if (discont and i == 3) b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        var r: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "push-buffer", b, &r);
        c.gst_buffer_unref(b);
    }
    var r: c.GstFlowReturn = 0;
    c.g_signal_emit_by_name(src, "end-of-stream", &r);
    drain(sink, "scope");
    const q = c.gst_query_new_latency();
    const sp = c.gst_element_get_static_pad(scope, "src");
    const qr = c.gst_pad_query(sp, q);
    var live: c.gboolean = 0;
    var min: u64 = 0;
    var max: u64 = 0;
    c.gst_query_parse_latency(q, &live, &min, &max);
    out("  latency {d} live={d} min={d} max={d}", .{ qr, live, min, @as(i64, @bitCast(max)) });
    c.gst_query_unref(q);
    c.gst_object_unref(sp);
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(pipe);
}

fn runPlugin(desc: [*c]const u8) void {
    out("plugin {s}", .{z(desc)});
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc, &err);
    if (pipe == null) {
        out("  parse error {s}", .{z(err[0].message)});
        return;
    }
    const sink = c.gst_bin_get_by_name(@ptrCast(pipe), "sink");
    _ = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    drain(sink, "plugin");
    _ = c.gst_element_set_state(pipe, c.GST_STATE_NULL);
    c.gst_object_unref(sink);
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.gst_init(null, null);
    const t = c.g_type_register_static_simple(c.gst_audio_visualizer_get_type(), "TScope", @sizeOf(c.GstAudioVisualizerClass), classInit, @sizeOf(c.GstAudioVisualizer), null, 0);
    out("type abstract={d} parent={s}", .{ @intFromBool(c.g_type_test_flags(c.gst_audio_visualizer_get_type(), c.G_TYPE_FLAG_ABSTRACT) != 0), z(c.g_type_name(c.g_type_parent(c.gst_audio_visualizer_get_type()))) });
    const e: ?*c.GstElement = @ptrCast(@alignCast(c.g_object_new(t, @as([*c]const u8, null))));
    var sh: c_int = 0;
    var am: c.guint = 0;
    c.g_object_get(e, "shader", &sh, "shade-amount", &am, NONE);
    out("defaults shader={d} amount={x}", .{ sh, am });
    var np: c.guint = 0;
    const specs = c.g_object_class_list_properties(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class)), &np);
    for (0..np) |i| out("prop {s} flags {d} type {s}", .{ z(specs[i][0].name), specs[i][0].flags, z(c.g_type_name(specs[i][0].value_type)) });
    var bogus = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&bogus, c.G_TYPE_INT);
    const ps = c.g_param_spec_int("bogus", "b", "b", 0, 1, 0, c.G_PARAM_READWRITE);
    const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(c.gst_audio_visualizer_get_type())));
    k.get_property.?(@ptrCast(@alignCast(e)), 9, &bogus, ps);
    k.set_property.?(@ptrCast(@alignCast(e)), 9, &bogus, ps);
    c.gst_object_unref(e);
    var s: c_int = 0;
    while (s < 10) : (s += 1) runScope(t, s, 0x000a0a0a, 8000, 1, 12, 9, false);
    runScope(t, 1, 0x00ff8040, 8000, 2, 7, 5, true);
    runScope(t, 8, 0x00000000, 11025, 1, 16, 4, false);
    runScope(t, 6, 0x00203040, 8000, 1, 5, 7, false);
    render_fail = true;
    runScope(t, 1, 0x000a0a0a, 8000, 1, 4, 4, false);
    render_fail = false;
    runPlugin("audiotestsrc num-buffers=6 samplesperbuffer=1024 ! audio/x-raw,rate=22050 ! goom ! video/x-raw,width=32,height=24,framerate=10/1 ! appsink name=sink sync=false");
}
