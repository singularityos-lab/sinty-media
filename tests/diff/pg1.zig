const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");

pub fn main() void {
    c.gst_init(null, null);
    d.inspect("pango");
    const srt = "1\n00:00:00,000 --> 00:00:00,050\nPrimo <b>sottotitolo</b>\n\n2\n00:00:00,050 --> 00:00:00,100\nSecond line\nwith wrap\n\n";
    const f = std.c.fopen("zig-out/pg1.srt", "w");
    if (f != null) {
        _ = std.c.fwrite(srt.ptr, 1, srt.len, f.?);
        _ = std.c.fclose(f.?);
    }
    const V = "videotestsrc num-buffers=2 ! video/x-raw,width=160,height=120,framerate=30/1,format=";
    const O = " ! fakesink name=out";
    inline for ([_][]const u8{ "I420", "RGBA", "YUY2", "NV12", "RGB", "BGRx", "ARGB", "AYUV", "GRAY8" }) |fmt| {
        d.run(V ++ fmt ++ " ! textoverlay text=Ciao shaded-background=true" ++ O);
    }
    inline for ([_][]const u8{ "halignment=left valignment=top", "halignment=right valignment=bottom", "halignment=position valignment=position xpos=0.2 ypos=0.7", "halignment=absolute valignment=absolute x-absolute=0.1 y-absolute=0.3", "valignment=center deltax=5 deltay=-3", "font-desc=\"Sans Bold 20\" draw-shadow=false", "draw-outline=false color=0xff00ff00", "outline-color=0xffff0000 shading-value=200 shaded-background=true", "wrap-mode=none text=\"una frase molto lunga che non entra nel riquadro\"", "wrap-mode=word text=\"una frase molto lunga che deve andare a capo\"", "line-alignment=left text=\"riga uno\nriga due piu lunga\"", "vertical-render=true", "auto-resize=false", "scale-mode=user scale-pixel-aspect-ratio=2/1", "response-time-compensation=true", "silent=true" }) |props| {
        d.run(V ++ "I420 ! textoverlay text=Prova " ++ props ++ O);
    }
    d.run(V ++ "I420 ! timeoverlay" ++ O);
    d.run(V ++ "I420 ! timeoverlay time-mode=buffer-count text=n" ++ O);
    d.run(V ++ "I420 ! timeoverlay time-mode=running-time halignment=right" ++ O);
    d.run(V ++ "I420 ! timeoverlay show-times-as-dates=true datetime-format=\"%Y-%m-%d\"" ++ O);
    d.run(V ++ "I420 ! clockoverlay time-format=fisso" ++ O);
    d.run("filesrc location=zig-out/pg1.srt ! subparse ! textrender ! video/x-raw,format=ARGB,width=200,height=80 ! fakesink name=out");
    d.run("filesrc location=zig-out/pg1.srt ! subparse ! textrender halignment=left valignment=top ! video/x-raw,format=AYUV ! fakesink name=out");
    d.run("filesrc location=zig-out/pg1.srt ! subparse ! textoverlay name=t ! fakesink name=out videotestsrc num-buffers=4 ! video/x-raw,format=I420,width=160,height=120,framerate=30/1 ! t.video_sink");
    d.out("done", .{});
}
