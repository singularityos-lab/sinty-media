const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const z = ins.z;

var lock: c.GMutex = std.mem.zeroes(c.GMutex);
var stream: [*c]c.GString = null;

fn out(comptime fmt: []const u8, args: anytype) void {
    ins.out(fmt, args);
}

fn sout(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt ++ "\n", args) catch return;
    c.g_mutex_lock(&lock);
    if (stream == null) stream = c.g_string_new(null);
    _ = c.g_string_append(stream, s.ptr);
    c.g_mutex_unlock(&lock);
}

fn flushStream() void {
    c.g_mutex_lock(&lock);
    if (stream != null) {
        const r = c.g_regex_new("stream-id=\\(string\\)[0-9a-f]+", 0, 0, null);
        const t0 = c.g_regex_replace_literal(r, stream[0].str, -1, 0, "stream-id=(string)ID", 0, null);
        const g = c.g_regex_new("group-id=\\(uint\\)[0-9]+", 0, 0, null);
        const t = c.g_regex_replace_literal(g, t0, -1, 0, "group-id=(uint)G", 0, null);
        _ = std.c.write(1, t, std.mem.len(@as([*:0]const u8, @ptrCast(t))));
        c.g_free(t0);
        c.g_free(t);
        c.g_regex_unref(r);
        c.g_regex_unref(g);
        _ = c.g_string_free(stream, 1);
        stream = null;
    }
    c.g_mutex_unlock(&lock);
}

fn lastMessage(o: ?*c.GObject, _: ?*c.GParamSpec, _: c.gpointer) callconv(.c) void {
    var s: [*c]u8 = null;
    c.g_object_get(o, "last-message", &s, @as(?*anyopaque, null));
    sout("  last {s}: {s}", .{ z(@as(*c.GstObject, @ptrCast(@alignCast(o))).name), z(s) });
    c.g_free(s);
}

fn handoff(e: ?*c.GstElement, b: [*c]c.GstBuffer, _: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    var map: c.GstMapInfo = undefined;
    var sum: u64 = 0;
    var size: usize = 0;
    if (c.gst_buffer_map(b, &map, c.GST_MAP_READ) != 0) {
        size = map.size;
        for (0..map.size) |i| sum = sum *% 31 +% map.data[i];
        c.gst_buffer_unmap(b, &map);
    }
    sout("  handoff {s} size={d} sum={d}", .{ z(@as(*c.GstObject, @ptrCast(@alignCast(e))).name), size, sum });
}

fn hook(bin: ?*c.GstElement) void {
    var it = c.gst_bin_iterate_recurse(@ptrCast(@alignCast(bin)));
    var v = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &v) == c.GST_ITERATOR_OK) {
        const e: ?*c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(&v)));
        const f = c.gst_element_get_factory(e);
        const fname = if (f != null) z(@as(*c.GstObject, @ptrCast(@alignCast(f))).name) else "";
        const cls: ?*c.GObjectClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class));
        if (c.g_object_class_find_property(cls, "last-message") != null) _ = c.g_signal_connect_data(e, "notify::last-message", @ptrCast(&lastMessage), null, null, 0);
        if (std.mem.eql(u8, fname, "fakesink") or std.mem.eql(u8, fname, "fakesrc") or std.mem.eql(u8, fname, "identity")) {
            _ = c.g_signal_connect_data(e, "handoff", @ptrCast(&handoff), null, null, 0);
        }
        if (std.mem.eql(u8, fname, "fakesink")) _ = c.g_signal_connect_data(e, "preroll-handoff", @ptrCast(&handoff), null, null, 0);
        _ = c.g_value_reset(&v);
    }
    c.g_value_unset(&v);
    c.gst_iterator_free(it);
    it = null;
}

fn showMessage(m: [*c]c.GstMessage) void {
    const src = if (m[0].src != null) z(m[0].src[0].name) else "-";
    switch (m[0].type) {
        c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            if (m[0].type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
            out("  msg {s} from {s}: {s} [{d}] / {s}", .{ z(c.gst_message_type_get_name(m[0].type)), src, if (e != null) z(e[0].message) else "-", if (e != null) e[0].code else 0, z(dbg) });
            c.g_clear_error(&e);
            c.g_free(dbg);
        },
        c.GST_MESSAGE_ELEMENT => {
            const st = c.gst_message_get_structure(m);
            const s = if (c.gst_structure_has_name(st, "GstCacheDownloadComplete") != 0) c.g_strdup("GstCacheDownloadComplete") else c.gst_structure_to_string(st);
            out("  msg element from {s}: {s}", .{ src, z(s) });
            c.g_free(s);
        },
        c.GST_MESSAGE_EOS, c.GST_MESSAGE_ASYNC_DONE, c.GST_MESSAGE_STREAM_START, c.GST_MESSAGE_SEGMENT_DONE => out("  msg {s} from {s}", .{ z(c.gst_message_type_get_name(m[0].type)), src }),
        else => {},
    }
}

pub fn run(desc: [*c]const u8, setup: ?*const fn (?*c.GstElement) void) void {
    out("pipeline {s}", .{z(desc)});
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc, &err);
    if (p == null) {
        out("  parse error {s}", .{if (err != null) z(err[0].message) else "-"});
        c.g_clear_error(&err);
        return;
    }
    if (err != null) {
        out("  parse warning {s}", .{z(err[0].message)});
        c.g_clear_error(&err);
    }
    hook(p);
    if (setup) |f| f(p);
    out("  state {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    while (true) {
        const m = c.gst_bus_timed_pop(bus, 5 * c.GST_SECOND);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        showMessage(m);
        const t = m[0].type;
        c.gst_mini_object_unref(@ptrCast(m));
        if (t == c.GST_MESSAGE_ERROR) c.g_usleep(200000);
        if (t == c.GST_MESSAGE_EOS or t == c.GST_MESSAGE_ERROR) break;
    }
    c.gst_object_unref(bus);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    flushStream();
    c.gst_object_unref(p);
}

fn printHandler(msg: [*c]const u8) callconv(.c) void {
    c.g_mutex_lock(&lock);
    if (stream == null) stream = c.g_string_new(null);
    _ = c.g_string_append(stream, msg);
    c.g_mutex_unlock(&lock);
}

fn toSecond(p: ?*c.GstElement) void {
    const s = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "s");
    const pad = c.gst_element_get_static_pad(s, "src_1");
    c.g_object_set(s, "active-pad", pad, @as(?*anyopaque, null));
    var got: ?*c.GstPad = null;
    c.g_object_get(s, "active-pad", &got, @as(?*anyopaque, null));
    out("  active {s}", .{z(@as(*c.GstObject, @ptrCast(@alignCast(got))).name)});
    c.gst_object_unref(got);
    const sink = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "k");
    const other = c.gst_element_get_static_pad(sink, "sink");
    c.g_object_set(s, "active-pad", other, @as(?*anyopaque, null));
    c.gst_object_unref(other);
    c.gst_object_unref(sink);
    c.gst_object_unref(pad);
    c.gst_object_unref(s);
}

fn haveType(_: ?*c.GstElement, prob: c.guint, caps: [*c]c.GstCaps, _: c.gpointer) callconv(.c) void {
    const t = c.gst_caps_to_string(caps);
    sout("  have-type {d} {s}", .{ prob, z(t) });
    c.g_free(t);
}

fn watchType(p: ?*c.GstElement) void {
    const t = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "t");
    _ = c.g_signal_connect_data(t, "have-type", @ptrCast(&haveType), null, null, 0);
    c.gst_object_unref(t);
}

fn toSink1(p: ?*c.GstElement) void {
    const s = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "i");
    const pad = c.gst_element_get_static_pad(s, "sink_1");
    c.g_object_set(s, "active-pad", pad, @as(?*anyopaque, null));
    var n: c.guint = 0;
    c.g_object_get(s, "n-pads", &n, @as(?*anyopaque, null));
    var act: c.gboolean = 0;
    c.g_object_get(pad, "active", &act, @as(?*anyopaque, null));
    out("  n-pads {d} active {d}", .{ n, act });
    const src = c.gst_element_get_static_pad(s, "src");
    c.g_object_set(s, "active-pad", src, @as(?*anyopaque, null));
    c.gst_object_unref(src);
    c.gst_object_unref(pad);
    c.gst_object_unref(s);
}

fn mqStats(p: ?*c.GstElement) void {
    const m = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "m");
    var st: ?*c.GstStructure = null;
    c.g_object_get(m, "stats", &st, @as(?*anyopaque, null));
    const t = c.gst_structure_to_string(st);
    out("  stats {s}", .{z(t)});
    c.g_free(t);
    c.gst_structure_free(st);
    const pad = c.gst_element_get_static_pad(m, "sink_0");
    if (pad != null) {
        var g: c.guint = 0;
        var lb: c.guint = 0;
        var lt: u64 = 0;
        c.g_object_set(pad, "group-id", @as(c.guint, 3), @as(?*anyopaque, null));
        c.g_object_get(pad, "group-id", &g, "current-level-buffers", &lb, "current-level-time", &lt, @as(?*anyopaque, null));
        out("  pad group {d} level {d} {d}", .{ g, lb, lt });
        c.gst_object_unref(pad);
    }
    c.gst_object_unref(m);
}

pub fn main() void {
    c.gst_init(null, null);
    _ = c.g_set_print_handler(printHandler);
    const S = " ! fakesink silent=false signal-handoffs=true";
    const list = [_][*c]const u8{
        "audiotestsrc num-buffers=3 samplesperbuffer=8 ! audio/x-raw,format=S16LE,rate=8000,channels=1" ++ S,
        "audiotestsrc num-buffers=3 samplesperbuffer=8 ! capsfilter caps=audio/x-raw,format=S16LE,rate=8000,channels=2" ++ S,
        "audiotestsrc num-buffers=2 samplesperbuffer=4 ! capsfilter caps=video/x-raw" ++ S,
        "audiotestsrc num-buffers=2 samplesperbuffer=4 ! capsfilter caps=audio/x-raw,rate=[1000,2000] caps-change-mode=delayed" ++ S,
        "videotestsrc num-buffers=2 ! video/x-raw,width=8,height=4,format=GRAY8" ++ S ++ " dump=true",
        "audiotestsrc num-buffers=5 samplesperbuffer=4 ! audio/x-raw,rate=4000" ++ S ++ " num-buffers=2",
        "audiotestsrc num-buffers=2 ! fakesink state-error=ready-to-paused",
        "audiotestsrc num-buffers=2 ! fakesink state-error=paused-to-playing",
        "audiotestsrc num-buffers=2 ! fakesink state-error=null-to-ready",
        "audiotestsrc num-buffers=2 samplesperbuffer=4 ! fakesink sync=true silent=false",
        "audiotestsrc num-buffers=3 samplesperbuffer=4 ! fakesink can-activate-pull=true can-activate-push=false",
    };
    for (list) |p| run(p, null);
    const F = "fakesrc num-buffers=3 silent=false signal-handoffs=true";
    const fl = [_][*c]const u8{
        F ++ S,
        F ++ " sizetype=fixed sizemax=8 filltype=pattern" ++ S,
        F ++ " sizetype=fixed sizemax=6 filltype=pattern-span" ++ S,
        F ++ " sizetype=fixed sizemax=5 filltype=zero datarate=10" ++ S,
        F ++ " sizetype=fixed sizemax=8 filltype=pattern-span data=subbuffer parentsize=20" ++ S,
        F ++ " sizetype=fixed sizemax=4 filltype=pattern dump=true format=time" ++ S,
        F ++ " sizetype=fixed sizemax=4 filltype=zero datarate=1000 sync=true" ++ S,
        F ++ " sizetype=fixed sizemax=4 filltype=zero can-activate-push=false" ++ S ++ " can-activate-pull=true can-activate-push=false",
        "fakesrc num-buffers=2 sizetype=fixed sizemax=3 filltype=pattern" ++ S ++ " can-activate-pull=true",
    };
    for (fl) |p| run(p, null);
    const A = "audiotestsrc num-buffers=4 samplesperbuffer=4 ! audio/x-raw,rate=4000,channels=1,format=S8 ! identity silent=false";
    const il = [_][*c]const u8{
        A ++ S,
        A ++ " dump=true" ++ S,
        A ++ " error-after=2" ++ S,
        A ++ " eos-after=3" ++ S,
        A ++ " eos-after=3 error-after=2" ++ S,
        A ++ " datarate=8" ++ S,
        A ++ " single-segment=true" ++ S,
        A ++ " check-imperfect-timestamp=true check-imperfect-offset=true" ++ S,
        "fakesrc num-buffers=3 sizetype=fixed sizemax=4 filltype=zero datarate=8 ! identity silent=false check-imperfect-offset=true check-imperfect-timestamp=true" ++ S,
        A ++ " drop-buffer-flags=discont" ++ S,
        A ++ " sync=true" ++ S,
        A ++ " signal-handoffs=false drop-allocation=true" ++ S,
        "audiotestsrc num-buffers=3 samplesperbuffer=4 is-live=true ! identity sync=true silent=true ! fakesink",
    };
    for (il) |p| run(p, null);
    const B = "audiotestsrc num-buffers=5 samplesperbuffer=4 ! audio/x-raw,rate=4000,channels=1,format=S8 ! ";
    const ql = [_][*c]const u8{
        B ++ "queue" ++ S,
        B ++ "queue max-size-buffers=1" ++ S,
        B ++ "queue min-threshold-buffers=3 max-size-time=0 max-size-bytes=0" ++ S,
        B ++ "queue max-size-buffers=2 leaky=upstream silent=true" ++ S ++ " sync=false",
        B ++ "queue ! queue ! queue" ++ S,
        "fakesrc num-buffers=3 sizetype=fixed sizemax=4 filltype=pattern ! queue max-size-bytes=4" ++ S,
        "fakesrc num-buffers=3 ! queue ! fakesink num-buffers=1 silent=false",
    };
    for (ql) |p| run(p, null);
    const tl = [_][*c]const u8{
        B ++ "tee name=t silent=false" ++ S ++ " t." ++ S,
        B ++ "tee name=t" ++ S ++ " t." ++ S ++ " t." ++ S,
        B ++ "tee silent=false",
        B ++ "tee allow-not-linked=true",
        B ++ "tee name=t allow-not-linked=true t.src_5" ++ S ++ " t.src_2" ++ S,
        B ++ "tee name=t has-chain=false" ++ S,
        "fakesrc num-buffers=2 sizetype=fixed sizemax=3 filltype=pattern can-activate-push=false ! tee pull-mode=single" ++ S ++ " can-activate-pull=true",
    };
    for (tl) |p| run(p, null);
    const P = "fakesrc num-buffers=5 sizetype=fixed sizemax=100 filltype=pattern-span ! ";
    const fl2 = [_][*c]const u8{
        P ++ "filesink location=zig-out/ft1.bin",
        "filesrc location=zig-out/ft1.bin blocksize=128" ++ S,
        P ++ "filesink location=zig-out/ft1.bin append=true buffer-mode=unbuffered",
        "filesrc location=zig-out/ft1.bin blocksize=300" ++ S ++ " can-activate-pull=true num-buffers=4",
        P ++ "filesink location=zig-out/ft2.bin buffer-mode=full buffer-size=150",
        P ++ "filesink location=zig-out/ft2.bin file-mode=overwrite buffer-mode=line buffer-size=10",
        "filesrc location=zig-out/ft2.bin blocksize=333" ++ S,
        "filesrc location=zig-out/does-not-exist.bin" ++ S,
        "filesrc location=zig-out" ++ S,
        "filesrc" ++ S,
        P ++ "filesink",
        P ++ "filesink location=/proc/nope/x.bin",
        "filesrc location=zig-out/ft1.bin ! queue ! filesink location=zig-out/ft3.bin",
    };
    for (fl2) |p| run(p, null);
    const vl = [_][*c]const u8{
        B ++ "funnel" ++ S,
        B ++ "funnel name=f forward-sticky-events=false f.sink_7" ++ S,
        B ++ "valve" ++ S,
        B ++ "valve drop=true drop-mode=forward-sticky-events" ++ S,
        B ++ "valve drop=true drop-mode=transform-to-gap" ++ S,
        B ++ "clocksync" ++ S,
        B ++ "clocksync sync=false" ++ S,
        B ++ "clocksync qos=true ts-offset=-5000000" ++ S,
        B ++ "clocksync sync-to-first=true rate=4.0" ++ S,
        B ++ "streamiddemux name=d d.src_0" ++ S,
        B ++ "streamiddemux name=d d.src_1" ++ S,
    };
    for (vl) |p| run(p, null);
    const rfd = c.open("zig-out/ft1.bin", c.O_RDONLY);
    run(c.g_strdup_printf("fdsrc fd=%d blocksize=700" ++ S, rfd), null);
    _ = c.close(rfd);
    const wfd = c.open("zig-out/ft4.bin", c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    run(c.g_strdup_printf(P ++ "fdsink fd=%d", wfd), null);
    _ = c.close(wfd);
    const cfd = c.open("zig-out/ft1.bin", c.O_RDONLY);
    const dfd = c.open("zig-out/ft5.bin", c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    run(c.g_strdup_printf("fdsrc fd=%d ! fdsink fd=%d", cfd, dfd), null);
    _ = c.close(cfd);
    _ = c.close(dfd);
    run("fakesrc num-buffers=0 ! fdsink fd=999", null);
    const du = [_][*c]const u8{
        "dataurisrc uri=\"data:,Hello%20World\"" ++ S ++ " dump=true",
        "dataurisrc uri=\"data:text/plain;charset=iso-8859-1,caf%E9\"" ++ S ++ " dump=true",
        "dataurisrc uri=\"data:;base64,SGVsbG8gYmFzZTY0\"" ++ S ++ " dump=true",
        "dataurisrc uri=\"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==\" blocksize=20" ++ S,
        "dataurisrc uri=\"nodata\"" ++ S,
        "dataurisrc" ++ S,
    };
    for (du) |p| run(p, null);
    const os = [_][*c]const u8{
        B ++ "output-selector name=s s.src_0" ++ S ++ " name=a s.src_1" ++ S ++ " name=k",
        B ++ "output-selector name=s pad-negotiation-mode=active s.src_0" ++ S ++ " name=a s.src_1" ++ S ++ " name=k",
        B ++ "output-selector name=s pad-negotiation-mode=none s.src_0" ++ S ++ " name=a s.src_1" ++ S ++ " name=k",
    };
    for (os) |p| run(p, null);
    run(B ++ "output-selector name=s s.src_0" ++ S ++ " name=a s.src_1" ++ S ++ " name=k", toSecond);
    const A4 = "audiotestsrc num-buffers=3 samplesperbuffer=4 ! audio/x-raw,rate=4000,channels=1,format=S8 ! ";
    const cc = [_][*c]const u8{
        "concat name=c" ++ S ++ " " ++ A4 ++ "c.sink_0 " ++ A4 ++ "c.sink_1",
        "concat name=c adjust-base=false" ++ S ++ " " ++ A4 ++ "c.sink_0 " ++ A4 ++ "c.sink_1",
        "concat name=c" ++ S ++ " fakesrc num-buffers=2 sizetype=fixed sizemax=10 filltype=zero ! c.sink_0 fakesrc num-buffers=3 sizetype=fixed sizemax=7 filltype=zero ! c.sink_1",
        "concat name=c" ++ S ++ " fakesrc num-buffers=2 sizetype=fixed sizemax=10 filltype=zero ! c.sink_0 " ++ A4 ++ "c.sink_1",
    };
    for (cc) |p| run(p, null);
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\xdac\xfc\xcf\xc0P\x0f\x00\x04\x85\x01\x80\x84\xa9\x8c!\x00\x00\x00\x00IEND\xaeB`\x82";
    _ = c.g_file_set_contents("zig-out/tf.png", png, png.len, null);
    _ = c.g_file_set_contents("zig-out/tf.dat", png, png.len, null);
    _ = c.g_file_set_contents("zig-out/tf0.dat", "", 0, null);
    const tf = [_][*c]const u8{
        "filesrc location=zig-out/tf.png ! typefind name=t" ++ S,
        "filesrc location=zig-out/tf.dat ! typefind name=t" ++ S,
        "filesrc location=zig-out/tf.png ! queue ! typefind name=t" ++ S,
        "filesrc location=zig-out/ft1.bin ! queue ! typefind name=t" ++ S,
        "filesrc location=zig-out/ft1.bin ! typefind name=t" ++ S,
        "filesrc location=zig-out/tf0.dat ! typefind name=t" ++ S,
        "filesrc location=zig-out/tf.png ! typefind name=t minimum=100" ++ S,
        "filesrc location=zig-out/tf.png ! queue ! typefind name=t force-caps=video/x-foo" ++ S,
        A4 ++ "typefind name=t" ++ S,
        "fakesrc num-buffers=3 sizetype=fixed sizemax=3000 filltype=zero ! typefind name=t" ++ S,
    };
    for (tf) |p| run(p, watchType);
    const is = [_][*c]const u8{
        "input-selector name=i" ++ S ++ " " ++ A4 ++ "i.sink_0 " ++ A4 ++ "i.sink_1",
        "input-selector name=i sync-streams=false" ++ S ++ " " ++ A4 ++ "i.sink_0 " ++ A4 ++ "i.sink_1",
        "input-selector name=i cache-buffers=true" ++ S ++ " " ++ A4 ++ "i.sink_0 " ++ A4 ++ "i.sink_1",
    };
    for (is) |p| run(p, null);
    run("input-selector name=i" ++ S ++ " " ++ A4 ++ "i.sink_0 " ++ A4 ++ "i.sink_1", toSink1);
    const Q = " ! fakesink silent=true";
    const mqs = [_][*c]const u8{
        A4 ++ "m.sink_0 multiqueue name=m m.src_0" ++ S,
        A4 ++ "m.sink_0 multiqueue name=m max-size-buffers=1 m.src_0" ++ S,
        A4 ++ "m.sink_0 multiqueue name=m use-buffering=true m.src_0" ++ S,
        A4 ++ "m.sink_0 multiqueue name=m sync-by-running-time=true use-interleave=true m.src_0" ++ S,
        A4 ++ "m.sink_0 " ++ A4 ++ "m.sink_1 multiqueue name=m m.src_0" ++ Q ++ " m.src_1" ++ Q,
        "fakesrc num-buffers=4 sizetype=fixed sizemax=8 filltype=zero ! m.sink_5 multiqueue name=m m.src_5" ++ S,
    };
    for (mqs) |p| run(p, mqStats);
    const dl = [_][*c]const u8{
        "filesrc location=zig-out/tf.png ! downloadbuffer temp-template=zig-out/dlXXXXXX ! typefind name=t" ++ S,
        "filesrc location=zig-out/ft1.bin ! downloadbuffer" ++ S,
        P ++ "downloadbuffer temp-template=zig-out/dlXXXXXX" ++ S,
    };
    for (dl) |p| run(p, watchType);
    run(B ++ "output-selector name=s resend-latest=true s.src_0" ++ S ++ " name=a s.src_1" ++ S ++ " name=k", toSecond);
    for ([_][*c]const u8{ "fd://0?size=100", "fd://abc", "file:///x" }) |u| {
        var e: [*c]c.GError = null;
        const el = c.gst_element_make_from_uri(c.GST_URI_SRC, u, null, &e);
        out("fd uri {s} {d}", .{ z(u), @intFromBool(el != null) });
        if (el != null) {
            const g = c.gst_uri_handler_get_uri(@ptrCast(el));
            out("  got {s}", .{z(g)});
            _ = c.gst_object_ref_sink(el);
            c.gst_object_unref(el);
        }
        if (e != null) c.g_error_free(e);
    }
    for ([_][*c]const u8{ "zig-out/ft1.bin", "zig-out/ft2.bin", "zig-out/ft3.bin", "zig-out/ft4.bin", "zig-out/ft5.bin" }) |f| {
        var data: [*c]u8 = null;
        var len: c.gsize = 0;
        if (c.g_file_get_contents(f, &data, &len, null) != 0) {
            var sum: u64 = 0;
            for (0..len) |i| sum = sum *% 31 +% data[i];
            out("file {s} len={d} sum={d}", .{ z(f), len, sum });
            c.g_free(data);
        }
    }
    const cwd = c.g_get_current_dir();
    const uri = c.g_strdup_printf("file://%s/zig-out/ft1.bin", cwd);
    var err: [*c]c.GError = null;
    const fs = c.gst_element_make_from_uri(c.GST_URI_SRC, uri, null, &err);
    out("uri src {d}", .{@intFromBool(fs != null)});
    if (fs != null) {
        var loc: [*c]u8 = null;
        c.g_object_get(fs, "location", &loc, @as(?*anyopaque, null));
        const got = c.gst_uri_handler_get_uri(@ptrCast(fs));
        out("uri loc {s} {d}", .{ z(c.g_path_get_basename(loc)), @intFromBool(c.g_strcmp0(got, uri) == 0) });
        _ = c.gst_object_ref_sink(fs);
        c.gst_object_unref(fs);
    }
    const fk = c.gst_element_make_from_uri(c.GST_URI_SINK, "file://localhost/tmp/x.bin", null, &err);
    out("uri sink {d}", .{@intFromBool(fk != null)});
    if (fk != null) {
        var loc: [*c]u8 = null;
        c.g_object_get(fk, "location", &loc, @as(?*anyopaque, null));
        out("uri sink loc {s}", .{z(loc)});
        _ = c.gst_object_ref_sink(fk);
        c.gst_object_unref(fk);
    }
    const bad = c.gst_element_make_from_uri(c.GST_URI_SINK, "file://relative", null, &err);
    out("uri bad {d} {s}", .{ @intFromBool(bad != null), if (err != null) z(err[0].message) else "-" });
    out("done", .{});
}
