const std = @import("std");
const c = @import("c").c;
const d = @import("plugdump.zig");
const X = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("X11/Xlib.h");
});

var xid: u64 = 0;

fn wait(p: *c.GstElement) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    while (true) {
        const msg = c.gst_bus_timed_pop_filtered(bus, 8 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_ELEMENT);
        if (msg == null) {
            d.out("  timeout", .{});
            return;
        }
        defer c.gst_message_unref(msg);
        switch (msg[0].type) {
            c.GST_MESSAGE_ERROR => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                c.gst_message_parse_error(msg, &e, &dbg);
                d.out("  error {s}", .{if (e != null) std.mem.span(e[0].message) else "-"});
                c.g_clear_error(&e);
                c.g_free(dbg);
                return;
            },
            c.GST_MESSAGE_EOS => {
                d.out("  eos", .{});
                return;
            },
            else => {
                const st = c.gst_message_get_structure(msg);
                if (st != null and c.gst_structure_has_name(st, "have-window-handle") != 0) {
                    _ = c.gst_structure_get_uint64(st, "window-handle", &xid);
                    d.out("  have-window-handle", .{});
                }
            },
        }
    }
}

fn capture() void {
    const disp = X.XOpenDisplay(null) orelse return;
    defer _ = X.XCloseDisplay(disp);
    _ = X.XSync(disp, 0);
    var attr: X.XWindowAttributes = undefined;
    _ = X.XGetWindowAttributes(disp, @intCast(xid), &attr);
    const img = X.XGetImage(disp, @intCast(xid), 0, 0, @intCast(attr.width), @intCast(attr.height), X.AllPlanes, X.ZPixmap);
    if (img == null) {
        d.out("  capture failed", .{});
        return;
    }
    var s: u64 = 0;
    var lit: usize = 0;
    var y: c_int = 0;
    while (y < attr.height) : (y += 1) {
        var x: c_int = 0;
        while (x < attr.width) : (x += 1) {
            const px = img[0].f.get_pixel.?(img, x, y) & 0xffffff;
            s = s *% 31 +% px;
            if (px != 0) lit += 1;
        }
    }
    d.out("  capture {d}x{d} lit={d} sum={d}", .{ attr.width, attr.height, lit, s });
    _ = img[0].f.destroy_image.?(img);
}

fn shown(desc: [*:0]const u8) void {
    xid = 0;
    d.out("show {s}", .{desc});
    const p: *c.GstElement = @ptrCast(c.gst_parse_launch(desc, null));
    d.out("  state {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    wait(p);
    const sink = c.gst_bin_get_by_name(@ptrCast(p), "x");
    if (sink != null) {
        var w: u64 = 0;
        var h: u64 = 0;
        c.g_object_get(sink, "window-width", &w, "window-height", &h, @as(?*anyopaque, null));
        d.out("  window {d} {d}", .{ w, h });
        c.gst_object_unref(sink);
    }
    if (xid != 0) capture();
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn props() void {
    const e = c.gst_element_factory_make("xvimagesink", null);
    c.g_object_set(e, "hue", @as(c.gint, 300), "contrast", @as(c.gint, -200), "brightness", @as(c.gint, 5), "saturation", @as(c.gint, 1000), "device", "2", "pixel-aspect-ratio", "4/3", @as(?*anyopaque, null));
    var hue: c.gint = 0;
    var con: c.gint = 0;
    var bri: c.gint = 0;
    var sat: c.gint = 0;
    var dev: [*c]u8 = null;
    var name: [*c]u8 = null;
    var par: [*c]u8 = null;
    c.g_object_get(e, "hue", &hue, "contrast", &con, "brightness", &bri, "saturation", &sat, "device", &dev, "device-name", &name, "pixel-aspect-ratio", &par, @as(?*anyopaque, null));
    d.out("props {d} {d} {d} {d} {s} {s} {s}", .{ hue, con, bri, sat, std.mem.span(dev), if (name != null) std.mem.span(name) else "-", std.mem.span(par) });
    const list = c.gst_color_balance_list_channels(@ptrCast(e));
    d.out("channels {d}", .{c.g_list_length(@constCast(list))});
    d.out("balance type {d}", .{c.gst_color_balance_get_balance_type(@ptrCast(e))});
    c.g_free(dev);
    c.g_free(name);
    c.g_free(par);
    c.gst_object_unref(e);
}

pub fn main() void {
    c.gst_init(null, null);
    d.inspect("ximagesink");
    d.run("videotestsrc num-buffers=2 ! ximagesink display=:79");
    d.run("videotestsrc num-buffers=4 ! video/x-raw,width=64,height=48 ! ximagesink");
    shown("videotestsrc num-buffers=3 pattern=smpte ! video/x-raw,format=BGRx,width=160,height=120 ! ximagesink name=x");
    shown("videotestsrc num-buffers=3 pattern=checkers-8 ! video/x-raw,format=I420,width=96,height=64 ! videoconvert ! ximagesink name=x");
    shown("videotestsrc num-buffers=2 pattern=ball ! video/x-raw,format=BGRx,width=80,height=60,pixel-aspect-ratio=1/1 ! videocrop left=8 top=4 right=10 bottom=6 ! ximagesink name=x");
    shown("videotestsrc num-buffers=2 pattern=gradient ! video/x-raw,format=RGB16,width=50,height=40 ! videoconvert ! ximagesink name=x");
    d.run("videotestsrc num-buffers=2 ! video/x-raw,format=BGRx,width=40,height=30,pixel-aspect-ratio=4/3 ! ximagesink");
    d.run("videotestsrc num-buffers=3 ! video/x-raw,format=BGRx,width=40,height=30 ! ximagesink handle-events=false handle-expose=false synchronous=true force-aspect-ratio=false pixel-aspect-ratio=1/1");
    d.inspect("xvimagesink");
    d.run("videotestsrc num-buffers=2 ! xvimagesink display=:79");
    d.run("videotestsrc num-buffers=2 ! xvimagesink");
    d.run("videotestsrc num-buffers=2 ! xvimagesink device=3 double-buffer=false autopaint-colorkey=false colorkey=255 draw-borders=false");
    props();
    d.out("done", .{});
}
