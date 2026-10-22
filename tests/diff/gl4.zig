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
    if (err != null) {
        out("  parse warning {s}", .{z(err[0].message)});
        c.g_clear_error(&err);
    }
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

fn enumValues(t: c.GType) void {
    if (c.g_type_is_a(t, c.G_TYPE_ENUM) != 0) {
        const k: *c.GEnumClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
        for (0..k.n_values) |i| out("    value {d} {s} {s}", .{ k.values[i].value, z(k.values[i].value_name), z(k.values[i].value_nick) });
    } else if (c.g_type_is_a(t, c.G_TYPE_FLAGS) != 0) {
        const k: *c.GFlagsClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
        for (0..k.n_values) |i| out("    flag {x} {s} {s}", .{ k.values[i].value, z(k.values[i].value_name), z(k.values[i].value_nick) });
    }
}

fn describe(o: ?*c.GObject) void {
    const t = @as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class[0].g_type;
    var p = t;
    while (p != 0) : (p = c.g_type_parent(p)) out("  type {s}", .{z(c.g_type_name(p))});
    var ni: c.guint = 0;
    const ifs = c.g_type_interfaces(t, &ni);
    for (0..ni) |i| out("  iface {s}", .{z(c.g_type_name(ifs[i]))});
    c.g_free(@ptrCast(ifs));
    var n: c.guint = 0;
    const ps = c.g_object_class_list_properties(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(o))).g_class)), &n);
    for (0..n) |i| {
        const sp = ps[i];
        var dv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&dv, sp.*.value_type);
        c.g_param_value_set_default(sp, &dv);
        const d = c.g_strdup_value_contents(&dv);
        var cur: [*c]u8 = null;
        if (sp.*.flags & c.G_PARAM_READABLE != 0 and sp.*.value_type != c.gst_gl_context_get_type() and sp.*.value_type != c.gst_gl_shader_get_type()) {
            var cv = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&cv, sp.*.value_type);
            c.g_object_get_property(o, sp.*.name, &cv);
            cur = c.g_strdup_value_contents(&cv);
            c.g_value_unset(&cv);
        }
        out("  prop {s} {s} owner {s} flags {x} nick {s} blurb {s} default {s} value {s}", .{ z(sp.*.name), z(c.g_type_name(sp.*.value_type)), z(c.g_type_name(sp.*.owner_type)), sp.*.flags, z(c.g_param_spec_get_nick(sp)), z(c.g_param_spec_get_blurb(sp)), z(d), z(cur) });
        enumValues(sp.*.value_type);
        c.g_free(d);
        c.g_free(cur);
        c.g_value_unset(&dv);
    }
    c.g_free(@ptrCast(ps));
    p = t;
    while (p != 0) : (p = c.g_type_parent(p)) {
        var ns: c.guint = 0;
        const ids = c.g_signal_list_ids(p, &ns);
        for (0..ns) |i| {
            var q: c.GSignalQuery = undefined;
            c.g_signal_query(ids[i], &q);
            out("  signal {s} on {s} flags {x} params {d} return {s}", .{ z(q.signal_name), z(c.g_type_name(p)), q.signal_flags, q.n_params, z(c.g_type_name(q.return_type)) });
        }
        c.g_free(@ptrCast(ids));
        if (p == c.gst_element_get_type()) break;
    }
}

fn fname(p: anytype) [*c]u8 {
    return @as(*c.GstObject, @ptrCast(@alignCast(@constCast(p)))).name;
}

fn cmpName(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    return c.g_strcmp0(fname(a), fname(b));
}

fn inspect() void {
    const plugin = c.gst_registry_find_plugin(c.gst_registry_get(), "opengl");
    if (plugin == null) {
        out("no opengl plugin", .{});
        return;
    }
    out("plugin {s} {s} {s} {s}", .{ z(c.gst_plugin_get_name(plugin)), z(c.gst_plugin_get_description(plugin)), z(c.gst_plugin_get_version(plugin)), z(c.gst_plugin_get_license(plugin)) });
    c.gst_object_unref(plugin);
    var list = c.gst_registry_get_feature_list_by_plugin(c.gst_registry_get(), "opengl");
    list = c.g_list_sort(list, cmpName);
    var l = list;
    while (l != null) : (l = l[0].next) {
        const f: *c.GstElementFactory = @ptrCast(@alignCast(l[0].data));
        out("element {s} rank {d}", .{ z(fname(f)), c.gst_plugin_feature_get_rank(@ptrCast(@alignCast(f))) });
        for ([_][*c]const u8{ c.GST_ELEMENT_METADATA_LONGNAME, c.GST_ELEMENT_METADATA_KLASS, c.GST_ELEMENT_METADATA_DESCRIPTION, c.GST_ELEMENT_METADATA_AUTHOR }) |k| out("  meta {s}", .{z(c.gst_element_factory_get_metadata(f, k))});
        var t = c.gst_element_factory_get_static_pad_templates(f);
        while (t != null) : (t = t[0].next) {
            const pt: *c.GstStaticPadTemplate = @ptrCast(@alignCast(t[0].data));
            out("  template {s} {d} {d} {s}", .{ z(pt.name_template), pt.direction, pt.presence, z(pt.static_caps.string) });
        }
        const e = c.gst_element_factory_create(f, null);
        if (e == null) {
            out("  create failed", .{});
            continue;
        }
        describe(@ptrCast(e));
        c.gst_object_unref(e);
    }
    c.gst_plugin_feature_list_free(list);
}

pub fn main() void {
    _ = c.setenv("GST_GL_WINDOW", "surfaceless", 1);
    _ = c.setenv("GST_GL_PLATFORM", "egl", 1);
    _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
    _ = c.setenv("EGL_PLATFORM", "surfaceless", 1);
    c.gst_init(null, null);
    inspect();
    const R = "video/x-raw,format=RGBA";
    const V = "videotestsrc num-buffers=1 ! video/x-raw,format=RGBA,width=16,height=16,framerate=30/1 ! glupload ! ";
    const D = " ! gldownload ! " ++ R ++ " ! fakesink name=out";
    run("videotestsrc num-buffers=1 ! video/x-raw,format=RGBA,width=8,height=8 ! pngenc ! filesink location=zig-out/gl4.png");
    inline for ([_][]const u8{ "smpte", "snow", "black", "white", "red", "green", "blue", "checkers-1", "checkers-2", "checkers-4", "checkers-8", "circular", "blink", "mandelbrot" }) |pat| run("gltestsrc num-buffers=1 pattern=" ++ pat ++ " ! video/x-raw(memory:GLMemory),width=16,height=16,framerate=30/1" ++ D);
    inline for ([_][]const u8{ "identity", "mirror", "squeeze", "stretch", "tunnel", "fisheye", "twirl", "bulge", "square", "heat", "sepia", "xpro", "lumaxpro", "xray", "sin", "glow", "sobel", "blur", "laplacian" }) |fx| run(V ++ "gleffects_" ++ fx ++ D);
    run(V ++ "gleffects effect=sobel invert=true hswap=true" ++ D);
    run(V ++ "gltransformation rotation-z=45 scale-x=0.5 translation-x=0.1" ++ D);
    run(V ++ "gltransformation ortho=true rotation-x=30 pivot-x=0.5" ++ D);
    run(V ++ "glvideoflip method=clockwise" ++ D);
    run(V ++ "glvideoflip video-direction=horizontal-flip" ++ D);
    run(V ++ "gldeinterlace method=greedyh" ++ D);
    run(V ++ "glalpha method=custom target-r=255 target-g=0 target-b=0 angle=40" ++ D);
    run(V ++ "glalpha alpha=0.5" ++ D);
    run(V ++ "gloverlay location=zig-out/gl4.png offset-x=2 offset-y=3 alpha=0.7" ++ D);
    run(V ++ "gldifferencematte location=zig-out/gl4.png" ++ D);
    run(V ++ "glfilterapp" ++ D);
    run(V ++ "glfilterglass ! gldownload ! fakesink");
    run(V ++ "glfiltercube red=0.5 fovy=60" ++ D);
    run("videotestsrc num-buffers=1 ! video/x-raw,format=RGBA,width=32,height=16,framerate=30/1,multiview-mode=side-by-side ! glupload ! glstereosplit name=s s.left ! gldownload ! " ++ R ++ " ! fakesink name=out s.right ! gldownload ! fakesink");
    run("glsrcbin src=gltestsrc num-buffers=1 ! video/x-raw(memory:GLMemory),width=16,height=16 ! gldownload ! " ++ R ++ " ! fakesink name=out");
    run("glvideomixerelement name=m background=white sink_0::sizing-policy=keep-aspect-ratio sink_0::width=16 sink_0::height=8 ! video/x-raw(memory:GLMemory),width=16,height=16 ! gldownload ! " ++ R ++ " ! fakesink name=out gltestsrc num-buffers=1 ! video/x-raw(memory:GLMemory),width=8,height=8,framerate=30/1 ! m.");
    run("glvideomixerelement name=m background=transparent sink_0::crop-left=2 sink_0::blend-function-src-rgb=one ! video/x-raw(memory:GLMemory),width=16,height=16 ! gldownload ! " ++ R ++ " ! fakesink name=out gltestsrc num-buffers=1 pattern=checkers-2 ! video/x-raw(memory:GLMemory),width=16,height=16,framerate=30/1 ! m.");
    out("done", .{});
}
