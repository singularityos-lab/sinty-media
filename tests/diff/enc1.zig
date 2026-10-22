const std = @import("std");
const c = @import("c").c;
const ins = @import("inspect");
const out = ins.out;
const z = ins.z;

const A = std.heap.c_allocator;
const N: ?*anyopaque = null;

var count: usize = 0;
var bytes: usize = 0;
var hash = std.hash.Fnv1a_64.init();
var caps_str: [*c]u8 = null;

fn handoff(_: ?*c.GstElement, b: [*c]c.GstBuffer, pad: ?*c.GstPad, _: c.gpointer) callconv(.c) void {
    if (caps_str == null) {
        const caps = c.gst_pad_get_current_caps(pad);
        if (caps != null) {
            const st = c.gst_caps_get_structure(caps, 0);
            caps_str = if (c.gst_structure_has_field(st, "streamheader") != 0) c.g_strdup(c.gst_structure_get_name(st)) else c.gst_caps_to_string(caps);
            c.gst_caps_unref(caps);
        }
    }
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    count += 1;
    bytes += map.size;
    hash.update(map.data[0..map.size]);
    c.gst_buffer_unmap(b, &map);
}

fn listChildren(bin: ?*c.GstElement) void {
    const it = c.gst_bin_iterate_recurse(@ptrCast(@alignCast(bin)));
    defer c.gst_iterator_free(it);
    var names: std.ArrayList([]const u8) = .empty;
    var item = std.mem.zeroes(c.GValue);
    while (c.gst_iterator_next(it, &item) == c.GST_ITERATOR_OK) {
        const e: ?*c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(&item)));
        const f = c.gst_element_get_factory(e);
        const n = if (f != null) z(@as(*c.GstObject, @ptrCast(@alignCast(f))).name) else z(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(e))).g_class[0].g_type));
        names.append(A, n) catch unreachable;
        _ = c.g_value_reset(&item);
    }
    c.g_value_unset(&item);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.f);
    var line: std.ArrayList(u8) = .empty;
    for (names.items) |n| line.print(A, " {s}", .{n}) catch unreachable;
    out("  children{s}", .{line.items});
}

fn listPads(e: ?*c.GstElement) void {
    var line: std.ArrayList(u8) = .empty;
    var l = @as(*c.GstElement, @ptrCast(@alignCast(e))).pads;
    while (l != null) : (l = l.*.next) {
        const name = c.gst_object_get_name(@ptrCast(@alignCast(l.*.data)));
        line.print(A, " {s}", .{z(name)}) catch unreachable;
        c.g_free(name);
    }
    out("  pads{s}", .{line.items});
}

fn scenario(title: []const u8, src: []const u8, profile: [:0]const u8, props: []const u8) void {
    out("scenario {s}", .{title});
    const desc = std.fmt.allocPrintSentinel(A, "{s} ! encodebin name=e {s} ! fakesink name=sink signal-handoffs=true sync=false", .{ src, props }, 0) catch unreachable;
    var err: [*c]c.GError = null;
    const p = c.gst_parse_launch(desc.ptr, &err);
    if (p == null) {
        out("  parse error {s}", .{z(err.*.message)});
        c.g_clear_error(&err);
        return;
    }
    if (err != null) {
        out("  parse warning {s}", .{z(err.*.message)});
        c.g_clear_error(&err);
    }
    const binp: *c.GstBin = @ptrCast(@alignCast(p));
    const e = c.gst_bin_get_by_name(binp, "e");
    const sink = c.gst_bin_get_by_name(binp, "sink");
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    count = 0;
    bytes = 0;
    hash = std.hash.Fnv1a_64.init();
    c.g_free(caps_str);
    caps_str = null;
    _ = profile;
    listPads(e);
    listChildren(e);
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    while (true) {
        const m = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR | c.GST_MESSAGE_ELEMENT);
        if (m == null) {
            out("  timeout", .{});
            break;
        }
        defer c.gst_message_unref(m);
        if (m.*.type == c.GST_MESSAGE_ELEMENT) {
            const st = c.gst_message_get_structure(m);
            out("  element {s} missing {d}", .{ z(c.gst_structure_get_name(st)), c.gst_is_missing_plugin_message(m) });
            continue;
        }
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var ge: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &ge, &dbg);
            const d = z(dbg);
            const cut = if (std.mem.indexOf(u8, d, ": /")) |i| d[0..i] else d;
            out("  error {s} {d} [{s}] [{s}]", .{ z(c.g_quark_to_string(ge.*.domain)), ge.*.code, z(ge.*.message), cut });
            c.g_error_free(ge);
            c.g_free(dbg);
        } else out("  eos", .{});
        break;
    }
    out("  caps {s}", .{z(caps_str)});
    out("  buffers {d} bytes {d}", .{ count, bytes });
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC, 0, 0, null, @constCast(@ptrCast(&handoff)), null);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(e);
    c.gst_object_unref(sink);
    c.gst_object_unref(p);
}

fn profileScenario(title: []const u8, profile_str: [:0]const u8, srcs: []const []const u8, flags: c.guint, avoid: bool) void {
    out("scenario {s}", .{title});
    const profile = c.gst_encoding_profile_from_string(profile_str.ptr);
    if (profile == null) {
        out("  no profile", .{});
        return;
    }
    const p = c.gst_pipeline_new("p");
    const e = c.gst_element_factory_make("encodebin", "e");
    const sink = c.gst_element_factory_make("fakesink", "sink");
    c.g_object_set(sink, "signal-handoffs", @as(c.gboolean, 1), "sync", @as(c.gboolean, 0), N);
    c.g_object_set(e, "flags", flags, "avoid-reencoding", @as(c.gboolean, @intFromBool(avoid)), N);
    c.g_object_set(e, "profile", profile, N);
    c.gst_object_unref(profile);
    _ = c.gst_bin_add(@ptrCast(@alignCast(p)), e);
    _ = c.gst_bin_add(@ptrCast(@alignCast(p)), sink);
    out("  link {d}", .{c.gst_element_link(e, sink)});
    _ = c.g_signal_connect_data(sink, "handoff", @ptrCast(&handoff), null, null, 0);
    for (srcs, 0..) |s, i| {
        var err: [*c]c.GError = null;
        const sd = std.fmt.allocPrintSentinel(A, "{s}", .{s}, 0) catch unreachable;
        const sb = c.gst_parse_bin_from_description(sd.ptr, 1, &err);
        if (sb == null) {
            out("  input {d} parse error {s}", .{ i, z(err.*.message) });
            continue;
        }
        _ = c.gst_bin_add(@ptrCast(@alignCast(p)), sb);
        const sp = c.gst_element_get_static_pad(sb, "src");
        const caps = c.gst_pad_query_caps(sp, null);
        var pad: ?*c.GstPad = null;
        c.g_signal_emit_by_name(e, "request-pad", caps, &pad);
        c.gst_caps_unref(caps);
        if (pad == null) {
            var l = @as(*c.GstElement, @ptrCast(@alignCast(e))).sinkpads;
            while (l != null and pad == null) : (l = l.*.next) {
                const cand: ?*c.GstPad = @ptrCast(l.*.data);
                if (c.gst_pad_is_linked(cand) == 0) pad = @ptrCast(c.gst_object_ref(cand));
            }
        }
        if (pad == null) pad = c.gst_element_request_pad_simple(e, if (std.mem.startsWith(u8, s, "videotestsrc")) "video_%u" else "audio_%u");
        if (pad == null) {
            out("  input {d} no pad", .{i});
            c.gst_object_unref(sp);
            continue;
        }
        const pn = c.gst_object_get_name(@ptrCast(@alignCast(pad)));
        out("  input {d} pad {s} link {d}", .{ i, z(pn), c.gst_pad_link(sp, pad) });
        c.g_free(pn);
        c.gst_object_unref(pad);
        c.gst_object_unref(sp);
    }
    count = 0;
    bytes = 0;
    hash = std.hash.Fnv1a_64.init();
    c.g_free(caps_str);
    caps_str = null;
    listPads(e);
    listChildren(e);
    out("  playing {d}", .{c.gst_element_set_state(p, c.GST_STATE_PLAYING)});
    const bus = c.gst_element_get_bus(p);
    const m = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    if (m == null) {
        out("  timeout", .{});
    } else {
        if (m.*.type == c.GST_MESSAGE_ERROR) {
            var ge: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(m, &ge, &dbg);
            out("  error {s} {d} [{s}]", .{ z(c.g_quark_to_string(ge.*.domain)), ge.*.code, z(ge.*.message) });
            c.g_error_free(ge);
            c.g_free(dbg);
        } else out("  eos", .{});
        c.gst_message_unref(m);
    }
    out("  caps {s}", .{z(caps_str)});
    out("  buffers {d} bytes {d}", .{ count, bytes });
    _ = c.g_signal_handlers_disconnect_matched(sink, c.G_SIGNAL_MATCH_FUNC, 0, 0, null, @constCast(@ptrCast(&handoff)), null);
    out("  null {d}", .{c.gst_element_set_state(p, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(p);
}

pub fn main() void {
    c.gst_init(null, null);
    for ([_][*c]const u8{ "encodebin", "encodebin2" }) |n| ins.element(n);
    const audio = "audiotestsrc num-buffers=20 samplesperbuffer=1024 ! capsfilter caps=audio/x-raw,rate=44100,channels=2,format=S16LE";
    const video = "videotestsrc num-buffers=5 pattern=smpte ! capsfilter caps=video/x-raw,width=64,height=48,framerate=10/1,format=I420";
    profileScenario("flac stream", "audio/x-flac", &.{audio}, 0, false);
    profileScenario("raw audio", "audio/x-raw,format=S16LE", &.{audio}, 0, false);
    profileScenario("jpeg stream", "image/jpeg", &.{video}, 0, false);
    profileScenario("jpeg no conversion", "image/jpeg", &.{video}, 2, false);
    profileScenario("ogg flac", "application/ogg:audio/x-flac", &.{audio}, 0, false);
    profileScenario("matroska two", "video/x-matroska:image/jpeg:audio/x-flac", &.{ video, audio }, 0, false);
    profileScenario("missing encoder", "video/x-h265", &.{video}, 0, false);
    profileScenario("missing muxer", "video/x-nothing:audio/x-flac", &.{audio}, 0, false);
    profileScenario("avoid reencoding", "image/jpeg", &.{video}, 0, true);
    scenario("no profile", audio, "", "");
    out("done", .{});
}
