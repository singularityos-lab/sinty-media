const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "-" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

var frames: u32 = 0;

fn handoff(_: ?*c.GstElement, buf: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    if (frames == 0) {
        const caps = c.gst_pad_get_current_caps(pad);
        const s = c.gst_caps_to_string(caps);
        out("  caps {s}", .{z(s)});
        c.g_free(s);
        c.gst_caps_unref(caps);
    }
    frames += 1;
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(buf, &map, c.GST_MAP_READ) == 0) {
        out("  frame {d} map failed", .{frames});
        return;
    }
    var s: u64 = 0;
    for (0..map.size) |i| s = s *% 31 +% map.data[i];
    out("  frame {d} size={d} pts={d} sum={d}", .{ frames, map.size, buf[0].pts, s });
    c.gst_buffer_unmap(buf, &map);
}

fn run(desc: [*c]const u8) void {
    out("pipeline {s}", .{z(desc)});
    frames = 0;
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc, &err);
    if (p == null) {
        out("  parse error {s}", .{if (err != null) z(err[0].message) else "-"});
        return;
    }
    if (err != null) c.g_clear_error(&err);
    const sink = c.gst_bin_get_by_name(@ptrCast(p), "out");
    if (sink != null) {
        c.g_object_set(sink, "signal-handoffs", @as(c.gboolean, 1), @as(?*anyopaque, null));
        _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
        c.gst_object_unref(sink);
    }
    out("  state {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    const msg = c.gst_bus_timed_pop_filtered(bus, 8 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (msg == null) {
        out("  timeout", .{});
    } else if (msg[0].type == c.GST_MESSAGE_ERROR) {
        var e: [*c]c.GError = null;
        var dbg: [*c]u8 = null;
        c.gst_message_parse_error(msg, &e, &dbg);
        out("  error {s}", .{if (e != null) z(e[0].message) else "-"});
        c.g_clear_error(&e);
        c.g_free(dbg);
    } else out("  eos frames={d}", .{frames});
    if (msg != null) c.gst_message_unref(msg);
    c.gst_object_unref(bus);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

pub fn main() void {
    _ = c.setenv("GST_GL_WINDOW", "surfaceless", 1);
    _ = c.setenv("GST_GL_PLATFORM", "egl", 1);
    _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    _ = c.setenv("EGL_PLATFORM", "surfaceless", 1);
    c.gst_init(null, null);
    const R = "video/x-raw,format=RGBA";
    const list = [_][*c]const u8{
        "gltestsrc num-buffers=2 pattern=smpte ! video/x-raw(memory:GLMemory),width=32,height=16,framerate=30/1 ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "gltestsrc num-buffers=2 pattern=ball ! video/x-raw(memory:GLMemory),width=32,height=16,framerate=30/1 ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "gltestsrc num-buffers=2 pattern=mandelbrot ! video/x-raw(memory:GLMemory),width=24,height=24,framerate=30/1 ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "gltestsrc num-buffers=2 pattern=snow ! video/x-raw(memory:GLMemory),width=16,height=16,framerate=30/1 ! glcolorconvert ! video/x-raw(memory:GLMemory),format=NV12 ! gldownload ! fakesink name=out",
        "videotestsrc num-buffers=2 pattern=smpte ! video/x-raw,format=I420,width=32,height=16,framerate=30/1 ! glupload ! glcolorconvert ! " ++ "video/x-raw(memory:GLMemory),format=RGBA ! gldownload ! fakesink name=out",
        "videotestsrc num-buffers=2 pattern=bar ! video/x-raw,format=YUY2,width=32,height=16,framerate=30/1 ! glupload ! glcolorconvert ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! gleffects effect=mirror ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! gleffects effect=sepia ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glcolorscale ! video/x-raw(memory:GLMemory),width=16,height=8 ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 pattern=gradient ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glfilterbin filter=glcolorbalance ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glcolorbalance brightness=0.3 contrast=1.4 ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glfiltercube ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! gldeinterlace ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "glvideomixerelement name=m sink_1::xpos=8 sink_1::alpha=0.5 ! video/x-raw(memory:GLMemory),width=32,height=16 ! gldownload ! " ++ R ++ " ! fakesink name=out gltestsrc num-buffers=2 pattern=smpte ! video/x-raw(memory:GLMemory),width=32,height=16,framerate=30/1 ! m. gltestsrc num-buffers=2 pattern=checkers-8 ! video/x-raw(memory:GLMemory),width=16,height=16,framerate=30/1 ! m.",
        "glvideomixer name=m background=black ! gldownload ! " ++ R ++ " ! fakesink name=out videotestsrc num-buffers=2 ! video/x-raw,format=I420,width=16,height=16,framerate=30/1 ! m. videotestsrc num-buffers=2 pattern=ball ! video/x-raw,format=RGBA,width=8,height=8,framerate=30/1 ! m.",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1,multiview-mode=side-by-side ! glupload ! glviewconvert output-mode-override=mono ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=16,height=16,framerate=30/1 ! glupload ! glviewconvert input-mode-override=top-bottom output-mode-override=side-by-side ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=NV12,width=32,height=16,framerate=30/1 ! glupload ! glcolorconvert ! glcolorscale ! video/x-raw(memory:GLMemory),format=Y444,width=8,height=8 ! gldownload ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glshader fragment=\"#version 100\n#ifdef GL_ES\nprecision mediump float;\n#endif\nvarying vec2 v_texcoord;\nuniform sampler2D tex;\nvoid main () { gl_FragColor = texture2D (tex, v_texcoord).bgra; }\" ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! glalpha method=green ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "videotestsrc num-buffers=2 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1 ! glupload ! gloverlaycompositor ! gldownload ! " ++ R ++ " ! fakesink name=out",
        "gltestsrc num-buffers=1 ! video/x-raw(memory:GLMemory),format=RGBA,width=8,height=8,framerate=30/1 ! glmosaic name=m ! gldownload ! " ++ R ++ " ! fakesink name=out gltestsrc num-buffers=1 pattern=blue ! video/x-raw(memory:GLMemory),width=8,height=8,framerate=30/1 ! m.",
        "glstereomix name=m ! video/x-raw(memory:GLMemory),multiview-mode=side-by-side ! gldownload ! " ++ R ++ " ! fakesink name=out gltestsrc num-buffers=2 pattern=red ! video/x-raw(memory:GLMemory),width=8,height=8,framerate=30/1 ! m. gltestsrc num-buffers=2 pattern=blue ! video/x-raw(memory:GLMemory),width=8,height=8,framerate=30/1 ! m.",
    };
    for (list) |p| run(p);
    out("done", .{});
}
