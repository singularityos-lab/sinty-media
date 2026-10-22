const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;
const SEC: u64 = 1_000_000_000;

var dir_buf: [4096]u8 = undefined;
var dir: []const u8 = "";
var count: usize = 0;
var limit: usize = 400;
var nomore = std.atomic.Value(bool).init(false);
var sink_async: c.gboolean = 0;

fn readFile(p: [:0]const u8) ?[]u8 {
    var data: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(p.ptr, &data, &len, null) == 0) return null;
    return data[0..len];
}

fn writeFile(p: [:0]const u8, parts: []const []const u8) void {
    var all: std.ArrayList(u8) = .empty;
    defer all.deinit(A);
    for (parts) |x| all.appendSlice(A, x) catch unreachable;
    _ = c.g_file_set_contents(p.ptr, all.items.ptr, @intCast(all.items.len), null);
}

fn path(name: []const u8) [:0]u8 {
    return std.fmt.allocPrintSentinel(A, "{s}/{s}", .{ dir, name }, 0) catch unreachable;
}

fn padName(p: ?*anyopaque) []const u8 {
    const o: *c.GstObject = @ptrCast(@alignCast(p orelse return "-"));
    return z(o.name);
}

const Held = struct { pad: ?*c.GstPad = null, name: [64]u8 = undefined, name_len: usize = 0, text: ?[*:0]u8 = null, lines: std.ArrayList(u8) = .empty, armed: bool = false, count: usize = 0 };
var held: [16]Held = [_]Held{.{}} ** 16;
var held_lock: c.GMutex = std.mem.zeroes(c.GMutex);
var grouping = false;

fn heldSlot(pad: ?*c.GstPad) *Held {
    for (&held) |*x| if (x.pad == pad) return x;
    for (&held) |*x| if (x.pad == null) {
        x.pad = pad;
        const n = padName(pad);
        x.name_len = @min(n.len, x.name.len);
        @memcpy(x.name[0..x.name_len], n[0..x.name_len]);
        return x;
    };
    return &held[0];
}

fn heldReset() void {
    for (&held) |*x| {
        if (x.text) |t| c.g_free(t);
        x.lines.deinit(A);
        x.* = .{};
    }
}

fn heldFlush() void {
    var order: [16]usize = undefined;
    var n: usize = 0;
    for (&held, 0..) |*x, i| if (x.pad != null) {
        order[n] = i;
        n += 1;
    };
    var i: usize = 1;
    while (i < n) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = &held[order[j - 1]];
            const b = &held[order[j]];
            if (std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) != .gt) break;
            std.mem.swap(usize, &order[j - 1], &order[j]);
        }
    }
    for (order[0..n]) |k| {
        const x = &held[k];
        var it = std.mem.splitScalar(u8, x.lines.items, '\n');
        while (it.next()) |l| if (l.len != 0) out("{s}", .{l});
        out("  {s} buffers {d}", .{ x.name[0..x.name_len], x.count });
    }
}

fn say(slot: *Held, comptime fmt: []const u8, args: anytype) void {
    if (grouping) {
        slot.lines.print(A, fmt ++ "\n", args) catch unreachable;
    } else out(fmt, args);
}

fn probe(pad: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const t = info[0].type;
    c.g_mutex_lock(&held_lock);
    defer c.g_mutex_unlock(&held_lock);
    const slot = heldSlot(pad);
    if (t & c.GST_PAD_PROBE_TYPE_BUFFER != 0) {
        if (grouping) {
            if (!slot.armed) return c.GST_PAD_PROBE_OK;
            slot.count += 1;
            if (slot.count > limit) return c.GST_PAD_PROBE_OK;
        } else {
            count += 1;
            if (count > limit) return c.GST_PAD_PROBE_OK;
        }
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(info[0].data));
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        const h = std.hash.Fnv1a_64.hash(map.data[0..map.size]);
        c.gst_buffer_unmap(b, &map);
        const flags = @as(*c.GstMiniObject, @ptrCast(@alignCast(b))).flags;
        say(slot, "  {s} buf pts {d} dur {d} off {d}/{d} flags {x} size {d} hash {x}", .{ padName(pad), @as(i64, @bitCast(b.*.pts)), @as(i64, @bitCast(b.*.duration)), @as(i64, @bitCast(b.*.offset)), @as(i64, @bitCast(b.*.offset_end)), flags & 0xfff0, map.size, h });
        const m: [*c]c.GstAudioClippingMeta = @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_audio_clipping_meta_api_get_type())));
        if (m != null) say(slot, "   clip {d} {d}", .{ m.*.start, m.*.end });
    } else if (t & c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM != 0) {
        const ev: [*c]c.GstEvent = @ptrCast(@alignCast(info[0].data));
        if (grouping and !slot.armed) {
            if (ev.*.type == c.GST_EVENT_FLUSH_STOP) slot.armed = true;
            return c.GST_PAD_PROBE_OK;
        }
        const st = c.gst_event_get_structure(ev);
        var s: [*c]u8 = null;
        if (st != null) s = c.gst_structure_to_string(st);
        defer c.g_free(s);
        var txt = z(s);
        if (txt.len > 1500) txt = txt[0..1500];
        var mask: [1600]u8 = undefined;
        if (std.mem.indexOf(u8, txt, "stream-id=(string)")) |i| {
            const st0 = i + 18;
            if (std.mem.indexOfScalarPos(u8, txt, st0, '/')) |sl| {
                if (sl - st0 == 32) {
                    @memcpy(mask[0..st0], txt[0..st0]);
                    mask[st0] = 'X';
                    @memcpy(mask[st0 + 1 .. st0 + 1 + txt.len - sl], txt[sl..]);
                    txt = mask[0 .. st0 + 1 + txt.len - sl];
                }
            }
        }
        if (ev.*.type == c.GST_EVENT_STREAM_START) {
            if (slot.text) |old| c.g_free(old);
            slot.text = c.g_strdup_printf("  %s event stream-start %.*s", padName(pad).ptr, @as(c_int, @intCast(txt.len)), txt.ptr);
            return c.GST_PAD_PROBE_OK;
        }
        if (slot.text) |ht| {
            say(slot, "{s}", .{z(ht)});
            c.g_free(ht);
            slot.text = null;
        }
        say(slot, "  {s} event {s} {s}", .{ padName(pad), z(c.gst_event_type_get_name(ev.*.type)), txt });
    }
    return c.GST_PAD_PROBE_OK;
}

fn attach(pad: ?*c.GstPad) void {
    _ = c.gst_pad_add_probe(pad, c.GST_PAD_PROBE_TYPE_BUFFER | c.GST_PAD_PROBE_TYPE_EVENT_DOWNSTREAM, probe, null, null);
}

fn padAdded(el: ?*c.GstElement, pad: ?*c.GstPad, data: c.gpointer) callconv(.c) void {
    const bin: ?*c.GstBin = @ptrCast(@alignCast(data));
    out("  pad-added {s}", .{padName(pad)});
    const sink = c.gst_element_factory_make("fakesink", null);
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), "async", sink_async, N);
    _ = c.gst_bin_add(bin, sink);
    _ = c.gst_element_sync_state_with_parent(sink);
    const sp = c.gst_element_get_static_pad(sink, "sink");
    attach(pad);
    _ = c.gst_pad_link(pad, sp);
    c.gst_object_unref(sp);
    _ = el;
}

fn noMore(_: ?*c.GstElement, _: c.gpointer) callconv(.c) void {
    nomore.store(true, .seq_cst);
    out("  no-more-pads", .{});
}

fn drain(p: ?*c.GstElement, secs: u64) void {
    const bus = c.gst_element_get_bus(p);
    defer c.gst_object_unref(bus);
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, secs * SEC, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_WARNING | c.GST_MESSAGE_ELEMENT | c.GST_MESSAGE_DURATION_CHANGED);
        if (m == null) {
            out("  timeout", .{});
            return;
        }
        defer c.gst_message_unref(m);
        switch (m.*.type) {
            c.GST_MESSAGE_ERROR, c.GST_MESSAGE_WARNING => {
                var e: [*c]c.GError = null;
                var dbg: [*c]u8 = null;
                if (m.*.type == c.GST_MESSAGE_ERROR) c.gst_message_parse_error(m, &e, &dbg) else c.gst_message_parse_warning(m, &e, &dbg);
                const d = z(dbg);
                const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
                out("  {s} {s} {d} [{s}] [{s}]", .{ z(c.gst_message_type_get_name(m.*.type)), z(c.g_quark_to_string(e.*.domain)), e.*.code, z(e.*.message), cut });
                c.g_error_free(e);
                c.g_free(dbg);
                if (m.*.type == c.GST_MESSAGE_ERROR) return;
            },
            c.GST_MESSAGE_EOS => {
                out("  eos", .{});
                return;
            },
            c.GST_MESSAGE_DURATION_CHANGED => out("  duration-changed", .{}),
            else => {
                const s = c.gst_structure_to_string(c.gst_message_get_structure(m));
                out("  element {s}", .{z(s)});
                c.g_free(s);
            },
        }
    }
}

fn queries(p: ?*c.GstElement) void {
    var d: i64 = 0;
    var pos: i64 = 0;
    const dr = c.gst_element_query_duration(p, c.GST_FORMAT_TIME, &d);
    const pr = c.gst_element_query_position(p, c.GST_FORMAT_TIME, &pos);
    out("  duration {d} {d} position {d}", .{ dr, d, pr });
    const q = c.gst_query_new_seeking(c.GST_FORMAT_TIME);
    if (c.gst_element_query(p, q) != 0) {
        var seekable: c.gboolean = 0;
        var start: i64 = 0;
        var stop: i64 = 0;
        c.gst_query_parse_seeking(q, null, &seekable, &start, &stop);
        out("  seeking {d} {d} {d}", .{ seekable, start, stop });
    }
    c.gst_query_unref(q);
}

fn launch(desc: []const u8) ?*c.GstElement {
    const d = A.dupeZ(u8, desc) catch unreachable;
    defer A.free(d);
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(d.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        return null;
    }
    return p;
}

const Branch = struct { desc: []const u8, templ: [:0]const u8, name: [:0]const u8 };

fn make(branches: []const Branch, props: []const u8, file: []const u8) void {
    const f = path(file);
    defer A.free(f);
    out("make {s}", .{file});
    const p = c.gst_pipeline_new("mk");
    const md = std.fmt.allocPrintSentinel(A, "oggmux name=m {s} ! filesink location={s}", .{ props, f }, 0) catch unreachable;
    defer A.free(md);
    var err: [*c]c.GError = null;
    const tail = c.gst_parse_bin_from_description(md.ptr, 1, &err);
    _ = c.gst_bin_add(@ptrCast(p), tail);
    const m = c.gst_bin_get_by_name(@ptrCast(@alignCast(tail)), "m");
    const k: *c.GstElementClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(m))).g_class));
    for (branches) |br| {
        const bd = A.dupeZ(u8, br.desc) catch unreachable;
        defer A.free(bd);
        const bin = c.gst_parse_bin_from_description(bd.ptr, 1, &err);
        _ = c.gst_bin_add(@ptrCast(p), bin);
        const sp = c.gst_element_get_static_pad(bin, "src");
        const mp = k.request_new_pad.?(m, c.gst_element_class_get_pad_template(k, br.templ.ptr), br.name.ptr, null);
        const gp = c.gst_ghost_pad_new(br.name.ptr, mp);
        _ = c.gst_pad_set_active(gp, 1);
        _ = c.gst_element_add_pad(tail, gp);
        out("  link {s} {d}", .{ padName(mp), c.gst_pad_link(sp, gp) });
        c.gst_object_unref(sp);
    }
    c.gst_object_unref(m);
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    drain(p, 30);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
    const data = readFile(f) orelse {
        out("  missing", .{});
        return;
    };
    defer c.g_free(data.ptr);
    out("  size {d} hash {x}", .{ data.len, std.hash.Fnv1a_64.hash(data) });
}

fn demux(file: []const u8, push: bool, seek: ?u64, flags: c.GstSeekFlags, rate: f64) void {
    const f = path(file);
    defer A.free(f);
    out("demux {s} push={} seek={?d} flags={x} rate={d}", .{ file, push, seek, flags, rate });
    const p = c.gst_pipeline_new("p");
    const src = c.gst_element_factory_make(if (push) "appsrc" else "filesrc", "src");
    if (!push) c.g_object_set(src, "location", f.ptr, N);
    const d = c.gst_element_factory_make("oggdemux", "d");
    _ = c.g_signal_connect_data(d, "pad-added", @ptrCast(&padAdded), p, null, 0);
    _ = c.g_signal_connect_data(d, "no-more-pads", @ptrCast(&noMore), null, null, 0);
    _ = c.gst_bin_add(@ptrCast(p), src);
    _ = c.gst_bin_add(@ptrCast(p), d);
    _ = c.gst_element_link(src, d);
    if (push) {
        c.g_object_set(src, "caps", c.gst_caps_new_empty_simple("application/ogg"), N);
        if (readFile(f)) |data| {
            var off: usize = 0;
            while (off < data.len) {
                const n = @min(4096, data.len - off);
                const b = c.gst_buffer_new_memdup(data.ptr + off, n);
                var r: c.GstFlowReturn = 0;
                c.g_signal_emit_by_name(src, "push-buffer", b, &r);
                c.gst_buffer_unref(b);
                off += n;
            }
            c.g_free(data.ptr);
        }
        var r: c.GstFlowReturn = 0;
        c.g_signal_emit_by_name(src, "end-of-stream", &r);
    }
    count = 0;
    heldReset();
    nomore.store(false, .seq_cst);
    sink_async = @intFromBool(seek != null);
    if (seek) |t| {
        _ = c.gst_element_set_state(p, c.GST_STATE_PAUSED);
        var w: usize = 0;
        while (!nomore.load(.seq_cst) and w < 500) : (w += 1) c.g_usleep(10000);
        _ = c.gst_element_get_state(p, null, null, 10 * SEC);
        queries(p);
        count = 0;
        c.g_mutex_lock(&held_lock);
        heldReset();
        grouping = true;
        c.g_mutex_unlock(&held_lock);
        out("  seek {d}", .{c.gst_element_seek(p, rate, c.GST_FORMAT_TIME, flags, c.GST_SEEK_TYPE_SET, @intCast(t), c.GST_SEEK_TYPE_NONE, -1)});
    }
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    drain(p, 20);
    queries(p);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    if (grouping) heldFlush() else out("  buffers {d}", .{count});
    grouping = false;
    heldReset();
    c.gst_object_unref(p);
}

fn parse(file: []const u8) void {
    const f = path(file);
    defer A.free(f);
    out("oggparse {s}", .{file});
    const desc = std.fmt.allocPrint(A, "filesrc location={s} ! oggparse name=o ! fakesink name=s", .{f}) catch unreachable;
    defer A.free(desc);
    const p = launch(desc) orelse return;
    const o = c.gst_bin_get_by_name(@ptrCast(@alignCast(p)), "o");
    const sp = c.gst_element_get_static_pad(o, "src");
    attach(sp);
    count = 0;
    heldReset();
    _ = c.gst_element_set_state(p, c.GST_STATE_PLAYING);
    drain(p, 20);
    out("  buffers {d}", .{count});
    c.gst_object_unref(sp);
    c.gst_object_unref(o);
    _ = c.gst_element_set_state(p, c.GST_STATE_NULL);
    c.gst_object_unref(p);
}

fn concat(a: []const u8, b: []const u8, outname: []const u8) void {
    const fa = path(a);
    const fb = path(b);
    const fo = path(outname);
    defer {
        A.free(fa);
        A.free(fb);
        A.free(fo);
    }
    const da = readFile(fa) orelse return;
    const db = readFile(fb) orelse return;
    writeFile(fo, &.{ da, db });
    c.g_free(da.ptr);
    c.g_free(db.ptr);
}

fn corrupt(a: []const u8, outname: []const u8) void {
    const fa = path(a);
    const fo = path(outname);
    defer {
        A.free(fa);
        A.free(fo);
    }
    const da = readFile(fa) orelse return;
    defer c.g_free(da.ptr);
    var i: usize = 3000;
    while (i < da.len) : (i += 1777) da[i] ^= 0x5a;
    if (da.len > 100) writeFile(fo, &.{da[0 .. da.len - 100]});
}

pub fn main() void {
    c.gst_init(null, null);
    var self: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &self, self.len);
    const d = std.fs.path.dirname(self[0..@intCast(n)]).?;
    @memcpy(dir_buf[0..d.len], d);
    dir = dir_buf[0..d.len];
    for ([_][:0]const u8{ "oggdemux", "oggmux", "oggparse", "ogmaudioparse", "ogmvideoparse", "ogmtextparse", "oggaviparse" }) |e| ins.element(e);
    const sine = "audiotestsrc num-buffers=60 samplesperbuffer=1024 ! audio/x-raw,rate=44100,channels=1";
    make(&.{.{ .desc = sine ++ " ! vorbisenc", .templ = "audio_%u", .name = "audio1111" }}, "", "a.ogg");
    make(&.{.{ .desc = "audiotestsrc num-buffers=50 samplesperbuffer=960 wave=triangle ! audio/x-raw,rate=48000,channels=2 ! opusenc", .templ = "audio_%u", .name = "audio2222" }}, "", "b.ogg");
    make(&.{ .{ .desc = "videotestsrc num-buffers=30 ! video/x-raw,width=64,height=48,framerate=15/1 ! theoraenc keyframe-force=8", .templ = "video_%u", .name = "video3333" }, .{ .desc = "audiotestsrc num-buffers=40 samplesperbuffer=1024 wave=square ! audio/x-raw,rate=22050,channels=2 ! vorbisenc", .templ = "audio_%u", .name = "audio4444" } }, "max-delay=200000000 max-page-delay=200000000", "c.ogg");
    make(&.{.{ .desc = "audiotestsrc num-buffers=30 samplesperbuffer=4096 ! audio/x-raw,rate=44100,channels=2 ! flacenc", .templ = "audio_%u", .name = "audio5555" }}, "", "e.ogg");
    make(&.{.{ .desc = "audiotestsrc num-buffers=30 ! audio/x-raw,rate=16000,channels=1 ! speexenc", .templ = "audio_%u", .name = "audio6666" }}, "", "f.ogg");
    make(&.{.{ .desc = "videotestsrc num-buffers=10 ! video/x-raw,width=32,height=32,framerate=5/1 ! theoraenc", .templ = "video_%u", .name = "video7777" }}, "max-tolerance=0", "g.ogg");
    concat("a.ogg", "b.ogg", "chain.ogg");
    corrupt("c.ogg", "bad.ogg");
    for ([_][]const u8{ "a.ogg", "b.ogg", "c.ogg", "e.ogg", "f.ogg", "g.ogg", "chain.ogg", "bad.ogg" }) |f| {
        limit = 400;
        demux(f, false, null, 0, 1.0);
        limit = 400;
        demux(f, true, null, 0, 1.0);
    }
    limit = 60;
    const fl = c.GST_SEEK_FLAG_FLUSH;
    demux("c.ogg", false, SEC, fl | c.GST_SEEK_FLAG_KEY_UNIT, 1.0);
    demux("c.ogg", false, 1500 * 1000 * 1000, fl | c.GST_SEEK_FLAG_ACCURATE, 1.0);
    demux("a.ogg", false, 700 * 1000 * 1000, fl, 1.0);
    demux("b.ogg", false, 500 * 1000 * 1000, fl | c.GST_SEEK_FLAG_KEY_UNIT, 1.0);
    demux("chain.ogg", false, 2 * SEC, fl, 1.0);
    demux("c.ogg", false, 0, fl | c.GST_SEEK_FLAG_SEGMENT, 1.0);
    demux("a.ogg", false, SEC, fl, -1.0);
    for ([_][]const u8{ "a.ogg", "c.ogg", "chain.ogg", "bad.ogg" }) |f| parse(f);
}
