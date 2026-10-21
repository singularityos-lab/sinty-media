const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn raw(p: [*c]const u8) void {
    if (p == null) {
        out("(null)", .{});
        return;
    }
    _ = std.c.write(1, p, c.strlen(p));
}

const Mode = enum(c_int) { slow = 0, fast = 1, turbo = 2 };

fn modeType() c.GType {
    const S = struct {
        var t: c.GType = 0;
        var vals = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "Slow mode", .value_nick = "slow" },
            .{ .value = 1, .value_name = "Fast mode", .value_nick = "fast" },
            .{ .value = 2, .value_name = "Turbo mode", .value_nick = "turbo" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
    };
    if (S.t == 0) S.t = c.g_enum_register_static("DotMode", &S.vals);
    return S.t;
}

fn optsType() c.GType {
    const S = struct {
        var t: c.GType = 0;
        var vals = [_]c.GFlagsValue{
            .{ .value = 1, .value_name = "Alpha", .value_nick = "alpha" },
            .{ .value = 2, .value_name = "Beta", .value_nick = "beta" },
            .{ .value = 4, .value_name = "Gamma", .value_nick = "gamma" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
    };
    if (S.t == 0) S.t = c.g_flags_register_static("DotOpts", &S.vals);
    return S.t;
}

const Node = extern struct {
    parent: c.GstElement,
    mode: c.gint,
    opts: c.guint,
    text: [*c]u8,
    level: f64,
};

fn nodeSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(o));
    switch (id) {
        1 => n.mode = c.g_value_get_enum(v),
        2 => n.opts = c.g_value_get_flags(v),
        3 => {
            c.g_free(n.text);
            n.text = c.g_value_dup_string(v);
        },
        4 => n.level = c.g_value_get_double(v),
        else => {},
    }
}

fn nodeGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const n: *Node = @ptrCast(@alignCast(o));
    switch (id) {
        1 => c.g_value_set_enum(v, n.mode),
        2 => c.g_value_set_flags(v, n.opts),
        3 => c.g_value_set_string(v, n.text),
        4 => c.g_value_set_double(v, n.level),
        else => {},
    }
}

fn props(gc: *c.GObjectClass) void {
    gc.set_property = nodeSet;
    gc.get_property = nodeGet;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("mode", "m", "m", modeType(), 0, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_flags("opts", "o", "o", optsType(), 0, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_string("text", "t", "t", null, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_double("level", "l", "l", 0, 100, 1, c.G_PARAM_READWRITE));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_double("hidden", "h", "h", 0, 100, 5, c.G_PARAM_WRITABLE));
}

fn template(k: c.gpointer, name: [*c]const u8, dir: c.GstPadDirection, presence: c.GstPadPresence, caps: [*c]const u8) void {
    const cp = c.gst_caps_from_string(caps);
    c.gst_element_class_add_pad_template(@ptrCast(@alignCast(k)), c.gst_pad_template_new(name, dir, presence, cp));
    c.gst_caps_unref(cp);
}

fn srcClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    props(@ptrCast(@alignCast(k)));
    template(k, "src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw, format=(string){ I420, YV12, NV12, NV21, RGBA, BGRA }, width=(int)[ 1, 2147483647 ], height=(int)[ 1, 2147483647 ], framerate=(fraction)[ 0/1, 2147483647/1 ], note=(string)\"a fairly long quoted note value\", size=(int)< 100, 200, 300, 400, 500, 600 >, list=(int){ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Src", "Source", "s", "x");
}

fn filterClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    props(@ptrCast(@alignCast(k)));
    template(k, "sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "video/x-raw; video/x-raw(memory:DMABuf, meta:Overlay)");
    template(k, "src_%u", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, "ANY");
    template(k, "aux_%u", c.GST_PAD_SRC, c.GST_PAD_REQUEST, "audio/x-raw, rate=(int)48000");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Filter", "Filter", "f", "x");
}

fn sinkClass(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    props(@ptrCast(@alignCast(k)));
    template(k, "sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "video/x-raw, format=(string)I420");
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Sink", "Sink", "k", "x");
}

fn nodeInit(instance: [*c]c.GTypeInstance, klass: c.gpointer) callconv(.c) void {
    const e: [*c]c.GstElement = @ptrCast(@alignCast(instance));
    const n: *Node = @ptrCast(@alignCast(instance));
    n.level = 1;
    var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(klass)));
    while (l != null) : (l = l.*.next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l.*.data));
        if (t[0].presence != c.GST_PAD_ALWAYS) continue;
        _ = c.gst_element_add_pad(e, c.gst_pad_new_from_template(t, t[0].name_template));
    }
}

fn reg(name: [*c]const u8, class_init: c.GClassInitFunc) c.GType {
    return c.g_type_register_static_simple(c.gst_element_get_type(), name, @sizeOf(c.GstElementClass), class_init, @sizeOf(Node), nodeInit, 0);
}

fn make(t: c.GType, name: [*c]const u8) [*c]c.GstElement {
    return @ptrCast(@alignCast(c.g_object_new(t, "name", name, @as(?*anyopaque, null))));
}

fn pad(e: [*c]c.GstElement, name: [*c]const u8) ?*c.GstPad {
    return c.gst_element_get_static_pad(e, name);
}

pub fn main() void {
    const dir = c.g_build_filename(c.g_get_current_dir(), "zig-out", "dotdir", @as([*c]const u8, null));
    _ = c.g_mkdir_with_parents(dir, 0o755);
    const old = c.g_dir_open(dir, 0, null);
    if (old != null) {
        while (c.g_dir_read_name(old)) |n| {
            const f = c.g_build_filename(dir, n, @as([*c]const u8, null));
            _ = std.c.unlink(f);
            c.g_free(f);
        }
        c.g_dir_close(old);
    }
    _ = c.g_setenv("GST_DEBUG_DUMP_DOT_DIR", dir, 1);
    c.g_set_application_name("dotapp");
    c.gst_init(null, null);
    const src_t = reg("DotSrc", srcClass);
    const filter_t = reg("DotFilter", filterClass);
    const sink_t = reg("DotSink", sinkClass);

    const pipe: [*c]c.GstBin = @ptrCast(@alignCast(c.gst_pipeline_new("pipe")));
    const src = make(src_t, "src");
    const inner: [*c]c.GstBin = @ptrCast(@alignCast(c.gst_bin_new("inner")));
    const filter = make(filter_t, "filter0");
    const sink = make(sink_t, "sink");
    const lonely = make(sink_t, "lonely");
    c.g_object_set(src, "mode", @as(c_int, 2), "opts", @as(c_uint, 5), "text", "short \"quoted\" text\twith tab", @as(?*anyopaque, null));
    c.g_object_set(filter, "text", "a very long property value that keeps on going and going well past the eighty character limit of the dot dump", "level", @as(f64, 42.5), "opts", @as(c_uint, 0), @as(?*anyopaque, null));
    c.g_object_set(sink, "mode", @as(c_int, 7), @as(?*anyopaque, null));
    _ = c.gst_bin_add(pipe, src);
    _ = c.gst_bin_add(pipe, @ptrCast(inner));
    _ = c.gst_bin_add(inner, filter);
    _ = c.gst_bin_add(pipe, sink);
    _ = c.gst_bin_add(pipe, lonely);

    const fsink = pad(filter, "sink");
    const gsink = c.gst_ghost_pad_new("gsink", fsink);
    _ = c.gst_element_add_pad(@ptrCast(inner), gsink);
    const fsrc = c.gst_pad_new_from_template(c.gst_element_class_get_pad_template(@ptrCast(@alignCast(@as([*c]c.GTypeInstance, @ptrCast(filter))[0].g_class)), "src_%u"), "src_0");
    _ = c.gst_element_add_pad(filter, fsrc);
    const req = c.gst_element_request_pad_simple(filter, "aux_%u");
    out("request pad {d}", .{@intFromBool(req != null)});
    const gsrc = c.gst_ghost_pad_new("gsrc", fsrc);
    _ = c.gst_element_add_pad(@ptrCast(inner), gsrc);
    const ssrc = pad(src, "src");
    out("link src {d}", .{c.gst_pad_link(ssrc, gsink)});
    const ksink = pad(sink, "sink");
    out("link sink {d}", .{c.gst_pad_link(gsrc, ksink)});
    const untargeted = c.gst_ghost_pad_new_no_target("loose", c.GST_PAD_SRC);
    _ = c.gst_element_add_pad(@ptrCast(inner), untargeted);

    const levels = [_]c.GstDebugGraphDetails{
        0,
        c.GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE,
        c.GST_DEBUG_GRAPH_SHOW_CAPS_DETAILS,
        c.GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS,
        c.GST_DEBUG_GRAPH_SHOW_STATES,
        c.GST_DEBUG_GRAPH_SHOW_FULL_PARAMS,
        c.GST_DEBUG_GRAPH_SHOW_NON_DEFAULT_PARAMS | c.GST_DEBUG_GRAPH_SHOW_FULL_PARAMS,
        c.GST_DEBUG_GRAPH_SHOW_ALL,
        c.GST_DEBUG_GRAPH_SHOW_VERBOSE,
    };
    for (levels) |lv| {
        out("===== details {d}", .{lv});
        const d = c.gst_debug_bin_to_dot_data(pipe, lv);
        raw(d);
        c.g_free(d);
    }

    _ = c.gst_element_set_locked_state(lonely, 1);
    out("state {d}", .{c.gst_element_set_state(@ptrCast(pipe), c.GST_STATE_READY)});
    @as([*c]c.GstObject, @ptrCast(@alignCast(ssrc)))[0].flags |= c.GST_PAD_FLAG_EOS | c.GST_PAD_FLAG_BLOCKED;
    out("===== ready states", .{});
    const d = c.gst_debug_bin_to_dot_data(pipe, c.GST_DEBUG_GRAPH_SHOW_STATES);
    raw(d);
    c.g_free(d);

    out("===== inner only", .{});
    const di = c.gst_debug_bin_to_dot_data(inner, c.GST_DEBUG_GRAPH_SHOW_ALL);
    raw(di);
    c.g_free(di);

    c.gst_debug_bin_to_dot_file(pipe, c.GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE, "named");
    c.gst_debug_bin_to_dot_file(pipe, c.GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE, null);
    c.gst_debug_bin_to_dot_file_with_ts(pipe, 0, "stamped");
    c.gst_debug_bin_to_dot_file_with_ts(pipe, 0, null);
    var names = std.ArrayList([]const u8).empty;
    const dh = c.g_dir_open(dir, 0, null);
    while (c.g_dir_read_name(dh)) |n| {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
        for (std.mem.span(n)) |ch| {
            buf[len] = if (std.ascii.isDigit(ch)) 'N' else ch;
            len += 1;
        }
        names.append(std.heap.c_allocator, std.heap.c_allocator.dupe(u8, buf[0..len]) catch return) catch return;
    }
    c.g_dir_close(dh);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    for (names.items) |n| out("file {s}", .{n});
    var contents: [*c]u8 = null;
    const f = c.g_build_filename(dir, "named.dot", @as([*c]const u8, null));
    if (c.g_file_get_contents(f, &contents, null, null) != 0) {
        const again = c.gst_debug_bin_to_dot_data(pipe, c.GST_DEBUG_GRAPH_SHOW_MEDIA_TYPE);
        out("named matches {d}", .{@intFromBool(c.g_strcmp0(contents, again) == 0)});
        c.g_free(again);
    }
    c.g_free(contents);

    out("crit {d}", .{@intFromBool(c.gst_debug_bin_to_dot_data(@ptrCast(src), 0) == null)});
    c.gst_debug_bin_to_dot_file(null, 0, "x");
    c.gst_debug_bin_to_dot_file_with_ts(null, 0, "x");
    _ = c.gst_element_set_state(@ptrCast(pipe), c.GST_STATE_NULL);
    c.gst_object_unref(pipe);
    out("done", .{});
}
