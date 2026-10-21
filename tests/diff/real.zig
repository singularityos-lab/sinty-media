const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const FACTORIES = [_][*:0]const u8{ "fakesrc", "fakesink", "identity", "queue", "tee", "capsfilter", "filesrc", "videotestsrc", "audiotestsrc", "videoconvert", "audioconvert", "audioresample", "videoscale", "decodebin", "playbin", "typefind" };

fn describe(name: [*:0]const u8) void {
    const f = c.gst_element_factory_find(name);
    if (f == null) {
        out("factory {s} missing", .{name});
        return;
    }
    defer c.gst_object_unref(f);
    const plugin = c.gst_plugin_feature_get_plugin_name(@ptrCast(f));
    out("factory {s} plugin={s} rank={d} klass={s} pads={d}", .{ name, str(plugin), c.gst_plugin_feature_get_rank(@ptrCast(f)), str(c.gst_element_factory_get_metadata(f, c.GST_ELEMENT_METADATA_KLASS)), c.gst_element_factory_get_num_pad_templates(f) });
    var l = c.gst_element_factory_get_static_pad_templates(f);
    while (l != null) : (l = l.*.next) {
        const t: [*c]c.GstStaticPadTemplate = @ptrCast(@alignCast(l.*.data));
        out("  template {s} dir={d} presence={d}", .{ str(t[0].name_template), t[0].direction, t[0].presence });
    }
    const e = c.gst_element_factory_create(f, null);
    if (e == null) {
        out("  create failed", .{});
        return;
    }
    _ = c.gst_object_ref_sink(e);
    var n: c.guint = 0;
    const props = c.g_object_class_list_properties(@ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(e))[0].g_class)), &n);
    out("  type={s} props={d}", .{ str(c.g_type_name(@as([*c]c.GTypeInstance, @ptrCast(e))[0].g_class[0].g_type)), n });
    c.g_free(@ptrCast(props));
    c.gst_object_unref(e);
}

var counted: c.guint = 0;

fn countProbe(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, _: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    if (info[0].type & c.GST_PAD_PROBE_TYPE_BUFFER != 0) _ = @atomicRmw(c.guint, &counted, .Add, 1, .seq_cst);
    return c.GST_PAD_PROBE_OK;
}

fn countSinks(it: ?*c.GstIterator) void {
    var item = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&item);
    while (c.gst_iterator_next(it, &item) == c.GST_ITERATOR_OK) {
        const e: [*c]c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(&item)));
        const p = c.gst_element_get_static_pad(e, "sink");
        if (p != null) {
            _ = c.gst_pad_add_probe(p, c.GST_PAD_PROBE_TYPE_BUFFER, countProbe, null, null);
            c.gst_object_unref(p);
        }
        _ = c.g_value_reset(&item);
    }
}

fn run(desc: [*:0]const u8) void {
    var err: [*c]c.GError = null;
    const pipe = c.gst_parse_launch(desc, &err);
    if (pipe == null) {
        out("pipeline '{s}' parse error {s}", .{ desc, str(err[0].message) });
        c.g_clear_error(&err);
        return;
    }
    if (err != null) {
        out("pipeline '{s}' warning {s}", .{ desc, str(err[0].message) });
        c.g_clear_error(&err);
    }
    counted = 0;
    const it = c.gst_bin_iterate_sinks(@ptrCast(pipe));
    countSinks(it);
    c.gst_iterator_free(it);
    const r = c.gst_element_set_state(pipe, c.GST_STATE_PLAYING);
    const bus = c.gst_element_get_bus(pipe);
    const msg = c.gst_bus_timed_pop_filtered(bus, 20 * c.GST_SECOND, c.GST_MESSAGE_EOS | c.GST_MESSAGE_ERROR);
    var what: []const u8 = "timeout";
    if (msg != null) {
        if (msg[0].type == c.GST_MESSAGE_EOS) {
            what = "eos";
        } else {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(msg, &e, &dbg);
            out("  error {s}", .{str(e[0].message)});
            c.g_clear_error(&e);
            c.g_free(dbg);
            what = "error";
        }
        c.gst_message_unref(msg);
    }
    var pos: c.gint64 = -1;
    _ = c.gst_element_query_position(pipe, c.GST_FORMAT_TIME, &pos);
    out("pipeline '{s}' start={d} end={s} buffers={d}", .{ desc, r, what, @atomicLoad(c.guint, &counted, .seq_cst) });
    out("  null {d}", .{c.gst_element_set_state(pipe, c.GST_STATE_NULL)});
    c.gst_object_unref(bus);
    c.gst_object_unref(pipe);
}

pub fn main() void {
    c.gst_init(null, null);
    const reg = c.gst_registry_get();
    const plugins = c.gst_registry_get_plugin_list(reg);
    var names = std.ArrayList([]const u8).empty;
    var l = plugins;
    while (l != null) : (l = l.*.next) names.append(std.heap.c_allocator, str(c.gst_plugin_get_name(@ptrCast(@alignCast(l.*.data))))) catch return;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |n| if (std.mem.eql(u8, n, "coreelements") or std.mem.eql(u8, n, "videotestsrc") or std.mem.eql(u8, n, "playback") or std.mem.eql(u8, n, "staticelements")) out("plugin {s}", .{n});
    c.gst_plugin_list_free(plugins);
    const feats = c.gst_registry_get_feature_list(reg, c.gst_element_factory_get_type());
    out("element factories {d}", .{@intFromBool(c.g_list_length(feats) > 100)});
    c.gst_plugin_feature_list_free(feats);
    for (FACTORIES) |f| describe(f);
    run("fakesrc num-buffers=50 ! queue ! identity ! fakesink sync=false");
    run("videotestsrc num-buffers=30 ! video/x-raw,width=320,height=240,format=I420 ! videoconvert ! video/x-raw,format=RGBA ! fakesink");
    run("audiotestsrc num-buffers=20 ! audioconvert ! audioresample ! audio/x-raw,rate=22050 ! fakesink");
    run("videotestsrc num-buffers=10 ! tee name=t ! queue ! fakesink t. ! queue ! fakesink");
    run("videotestsrc num-buffers=5 pattern=ball ! videoscale ! video/x-raw,width=64,height=48 ! fakesink sync=true");
    run("fakesrc num-buffers=3 ! nosuchelement ! fakesink");
    run("audiotestsrc num-buffers=4 ! video/x-raw ! fakesink");
    out("done", .{});
}
