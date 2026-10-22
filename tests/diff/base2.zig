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
    ins.out("done", .{});
}
