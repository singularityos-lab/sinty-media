const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const core = @import("core2.zig");

pub fn main() void {
    c.gst_init(null, null);
    _ = c.g_set_print_handler(core.printHandler);
    const S = " ! fakesink silent=false signal-handoffs=true";
    const T = "audiotestsrc num-buffers=3 samplesperbuffer=64 wave=sine ! ";
    const ac = [_][*c]const u8{
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioconvert ! audio/x-raw,format=F32LE" ++ S,
        T ++ "audio/x-raw,format=F32LE,rate=8000,channels=1 ! audioconvert ! audio/x-raw,format=S16LE" ++ S,
        T ++ "audio/x-raw,format=F32LE,rate=8000,channels=1 ! audioconvert dithering=none ! audio/x-raw,format=S8" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioconvert ! audio/x-raw,channels=2" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=2 ! audioconvert ! audio/x-raw,channels=1" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=2 ! audioconvert ! audio/x-raw,format=S16LE,layout=non-interleaved" ++ S,
        T ++ "audio/x-raw,format=S32BE,rate=8000,channels=6 ! audioconvert ! audio/x-raw,channels=2,format=F64LE" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioconvert" ++ S,
        T ++ "audio/x-raw,format=U8,rate=8000,channels=4 ! audioconvert input-channels-reorder=smpte input-channels-reorder-mode=force ! audio/x-raw,channels=2" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=2 ! audioconvert mix-matrix=\"<<(float)0.5,(float)0.5>>\" ! audio/x-raw,channels=1" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioconvert ! audio/x-raw,format=U24BE" ++ S,
        T ++ "audio/x-raw,format=F64LE,rate=8000,channels=1 ! audioconvert noise-shaping=high dithering=tpdf-hf ! audio/x-raw,format=S16LE" ++ S,
    };
    for (ac) |p| core.run(p, null);
    const ar = [_][*c]const u8{
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioresample ! audio/x-raw,rate=16000" ++ S,
        T ++ "audio/x-raw,format=F32LE,rate=8000,channels=2 ! audioresample ! audio/x-raw,rate=11025" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=48000,channels=1 ! audioresample quality=10 ! audio/x-raw,rate=44100" ++ S,
        T ++ "audio/x-raw,format=S32LE,rate=8000,channels=1 ! audioresample resample-method=linear ! audio/x-raw,rate=22050" ++ S,
        T ++ "audio/x-raw,format=F64LE,rate=22050,channels=1 ! audioresample resample-method=cubic sinc-filter-mode=full ! audio/x-raw,rate=8000" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! audioresample ! audio/x-raw,rate=8000" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=8000,channels=2 ! audioconvert ! audioresample ! audio/x-raw,rate=32000,channels=1,format=F32LE" ++ S,
        T ++ "audio/x-raw,format=S16LE,rate=16000,channels=1,layout=non-interleaved ! audioresample ! audio/x-raw,rate=8000" ++ S,
    };
    for (ar) |p| core.run(p, null);
    const D = " ! fakesink silent=false signal-handoffs=true dump=true";
    const V = "videotestsrc num-buffers=2 pattern=smpte ! ";
    const vc = [_][*c]const u8{
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvert ! video/x-raw,format=RGBA" ++ D,
        V ++ "video/x-raw,format=RGBA,width=16,height=8 ! videoconvert ! video/x-raw,format=I420" ++ D,
        V ++ "video/x-raw,format=NV12,width=16,height=8 ! videoconvert ! video/x-raw,format=YUY2" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvert ! video/x-raw,format=GRAY8" ++ D,
        V ++ "video/x-raw,format=RGB,width=16,height=8 ! videoconvert dither=none ! video/x-raw,format=RGB16" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvert" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale ! video/x-raw,width=8,height=4" ++ D,
        V ++ "video/x-raw,format=RGBA,width=16,height=8 ! videoscale method=nearest-neighbour ! video/x-raw,width=24,height=12" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale method=lanczos ! video/x-raw,width=24,height=12" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale ! video/x-raw,width=16,height=16" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale add-borders=false ! video/x-raw,width=16,height=16" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8,pixel-aspect-ratio=1/1 ! videoscale ! video/x-raw,height=4" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale ! video/x-raw,width=8" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8,pixel-aspect-ratio=4/3 ! videoscale ! video/x-raw,width=8,height=8" ++ D,
        V ++ "video/x-raw,format=NV12,width=16,height=8 ! videoconvertscale ! video/x-raw,format=BGRx,width=8,height=8" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvertscale method=mitchell ! video/x-raw,format=AYUV,width=20,height=10" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvertscale ! video/x-raw,format=Y444" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoconvert ! video/x-raw,width=8" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8 ! videoscale ! video/x-raw,format=RGBA" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8,interlace-mode=interleaved ! videoconvertscale ! video/x-raw,format=RGBA" ++ D,
        V ++ "video/x-raw,format=RGBA,width=16,height=8 ! videoconvert alpha-mode=set alpha-value=0.5 ! video/x-raw,format=ARGB" ++ D,
        V ++ "video/x-raw,format=I420,width=16,height=8,colorimetry=bt709 ! videoconvert ! video/x-raw,format=RGB" ++ D,
    };
    for (vc) |p| core.run(p, null);
    const A = "audiotestsrc num-buffers=3 samplesperbuffer=16 wave=sine volume=0.9 ! ";
    const vo = [_][*c]const u8{
        A ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! volume volume=0.5" ++ D,
        A ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! volume volume=1.7" ++ D,
        A ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! volume volume-full-range=40" ++ D,
        A ++ "audio/x-raw,format=S8,rate=8000,channels=1 ! volume volume=0.3" ++ D,
        A ++ "audio/x-raw,format=S8,rate=8000,channels=1 ! volume volume=3.3" ++ D,
        A ++ "audio/x-raw,format=S8,rate=8000,channels=1 ! volume volume-full-range=200" ++ D,
        A ++ "audio/x-raw,format=S24LE,rate=8000,channels=1 ! volume volume=0.7" ++ D,
        A ++ "audio/x-raw,format=S24LE,rate=8000,channels=1 ! volume volume=2.5" ++ D,
        A ++ "audio/x-raw,format=S24LE,rate=8000,channels=1 ! volume volume-full-range=33" ++ D,
        A ++ "audio/x-raw,format=S32LE,rate=8000,channels=1 ! volume volume=0.25" ++ D,
        A ++ "audio/x-raw,format=S32LE,rate=8000,channels=1 ! volume volume=9.9" ++ D,
        A ++ "audio/x-raw,format=S32LE,rate=8000,channels=1 ! volume volume-full-range=17" ++ D,
        A ++ "audio/x-raw,format=F32LE,rate=8000,channels=2 ! volume volume=0.123" ++ D,
        A ++ "audio/x-raw,format=F64LE,rate=8000,channels=2 ! volume volume=4.56" ++ D,
        A ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! volume volume=1.0" ++ D,
        A ++ "audio/x-raw,format=S16LE,rate=8000,channels=1 ! volume mute=true" ++ D,
        A ++ "audio/x-raw,format=F32LE,rate=8000,channels=1 ! volume volume=0" ++ D,
        A ++ "audio/x-raw,format=U8,rate=8000,channels=1 ! volume volume=0.5" ++ D,
    };
    for (vo) |p| core.run(p, null);
    const W = "audiotestsrc num-buffers=3 samplesperbuffer=24 ";
    const wv = [_][*c]const u8{
        W ++ "wave=square freq=1000 ! audio/x-raw,rate=8000" ++ D,
        W ++ "wave=saw freq=700 ! audio/x-raw,rate=8000,format=S32LE" ++ D,
        W ++ "wave=triangle freq=900 volume=0.4 ! audio/x-raw,rate=8000,format=F32LE" ++ D,
        W ++ "wave=silence ! audio/x-raw,rate=8000,format=F64LE" ++ D,
        W ++ "wave=sine-table freq=1234 ! audio/x-raw,rate=8000" ++ D,
        W ++ "wave=sine-table freq=400 volume=0.3 ! audio/x-raw,rate=8000,format=F32LE" ++ D,
        W ++ "wave=ticks freq=2000 tick-interval=5000000 sine-periods-per-tick=3 ! audio/x-raw,rate=8000" ++ D,
        W ++ "wave=ticks freq=1500 tick-interval=3000000 apply-tick-ramp=true marker-tick-period=2 marker-tick-volume=0.2 ! audio/x-raw,rate=8000,format=F64LE" ++ D,
        W ++ "wave=ticks freq=1500 tick-interval=3000000 apply-tick-ramp=true marker-tick-period=3 ! audio/x-raw,rate=8000,format=S32LE" ++ D,
        W ++ "! audio/x-raw,rate=8000,format=S24LE" ++ D,
        W ++ "wave=saw ! audio/x-raw,rate=8000,format=U8" ++ D,
        W ++ "! audio/x-raw,rate=8000,format=F32BE,channels=2" ++ D,
        W ++ "wave=triangle ! audio/x-raw,rate=8000,format=S16BE,channels=3" ++ D,
        W ++ "! audio/x-raw,rate=8000,format=U18LE" ++ D,
        W ++ "! audio/x-raw,rate=8000,channels=2,layout=non-interleaved" ++ D,
        W ++ "wave=square ! audio/x-raw,rate=8000,channels=4,format=F64BE,layout=non-interleaved" ++ D,
        W ++ "volume=0 ! audio/x-raw,rate=8000" ++ D,
        W ++ "timestamp-offset=123456 ! audio/x-raw,rate=8000" ++ S,
        W ++ "freq=30000" ++ S,
        W ++ "" ++ S,
        W ++ "! audio/x-raw,channels=6" ++ S,
    };
    for (wv) |p| core.run(p, null);
    const fmts = [_][]const u8{ "S8", "S16LE", "S24LE", "S32LE", "F32LE", "F64LE" };
    for (fmts) |f| {
        for ([_]u8{ '1', '2', '3' }) |ch| {
            var buf: [256]u8 = undefined;
            const d = std.fmt.bufPrintZ(&buf, "audiotestsrc num-buffers=3 samplesperbuffer=16 wave=sine ! audio/x-raw,format={s},rate=8000,channels={c} ! volume name=v{s}", .{ f, ch, D }) catch unreachable;
            core.run(d.ptr, ramp);
            core.run(d.ptr, muteRamp);
        }
    }
    ins.out("done", .{});
}

fn bind(p: ?*c.GstElement, prop: [*c]const u8, pts: []const [2]f64) void {
    const v = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "v");
    defer c.gst_object_unref(v);
    const cs = c.gst_interpolation_control_source_new();
    c.g_object_set(cs, "mode", c.GST_INTERPOLATION_MODE_LINEAR, @as(?*anyopaque, null));
    for (pts) |t| _ = c.gst_timed_value_control_source_set(@ptrCast(@alignCast(cs)), @intFromFloat(t[0] * 1e6), t[1]);
    _ = c.gst_object_add_control_binding(@ptrCast(@alignCast(v)), c.gst_direct_control_binding_new_absolute(@ptrCast(@alignCast(v)), prop, cs));
    c.gst_object_unref(cs);
}

fn ramp(p: ?*c.GstElement) void {
    bind(p, "volume", &.{ .{ 0, 0.2 }, .{ 5, 3.7 }, .{ 6, 9.5 } });
}

fn muteRamp(p: ?*c.GstElement) void {
    bind(p, "volume", &.{ .{ 0, 1.3 }, .{ 6, 0.4 } });
    bind(p, "mute", &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 2.1, 1 }, .{ 4, 1 }, .{ 4.1, 0 } });
}
