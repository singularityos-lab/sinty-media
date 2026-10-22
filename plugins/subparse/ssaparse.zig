const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const dt = @import("detect.zig");

const FILE = "../gst/subparse/gstssaparse.c";

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    framed: c.gboolean,
    send_tags: c.gboolean,
    ini: [*c]u8,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-ssa; application/x-ass");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "text/x-raw, format=pango-markup");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.ini);
    s.ini = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    return c.gst_pad_event_default(pad, par, e);
}

fn find(hay: [*c]const u8, len: usize, needle: []const u8) bool {
    if (needle.len > len) return false;
    return std.mem.indexOf(u8, hay[0..len], needle) != null;
}

fn setCaps(s: *Self, caps: [*c]c.GstCaps) bool {
    const st = c.gst_caps_get_structure(caps, 0);
    const val = c.gst_structure_get_value(st, "codec_data");
    if (val == null) {
        s.framed = 0;
        return false;
    }
    s.framed = 1;
    s.send_tags = 1;
    const priv: [*c]c.GstBuffer = @ptrCast(@alignCast(c.g_value_get_boxed(val)));
    if (!cm.that(priv != null, "gst_ssa_parse_setcaps", "priv != NULL")) return false;
    _ = c.gst_buffer_ref(priv);
    defer c.gst_buffer_unref(priv);
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(priv, &map, c.GST_MAP_READ) == 0) return false;
    var ptr: [*c]const u8 = map.data;
    var left = map.size;
    if (left >= 3 and ptr[0] == 0xEF and ptr[1] == 0xBB and ptr[2] == 0xBF) {
        ptr += 3;
        left -= 3;
    }
    if (!find(ptr, left, "[Script Info]")) {
        c.gst_buffer_unmap(priv, &map);
        return false;
    }
    var end: [*c]const u8 = null;
    if (c.g_utf8_validate(ptr, @intCast(left), &end) == 0) left = @intFromPtr(end) - @intFromPtr(ptr);
    c.g_free(s.ini);
    s.ini = c.g_strndup(ptr, left);
    c.gst_buffer_unmap(priv, &map);
    const out = c.gst_caps_new_simple("text/x-raw", "format", c.G_TYPE_STRING, "pango-markup", @as(?*anyopaque, null));
    defer c.gst_caps_unref(out);
    return cm.setCaps(s.srcpad, out);
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(e) != c.GST_EVENT_CAPS) return c.gst_pad_event_default(pad, par, e);
    var caps: [*c]c.GstCaps = null;
    c.gst_event_parse_caps(e, &caps);
    const ok = setCaps(me(par), caps);
    c.gst_event_unref(e);
    return @intFromBool(ok);
}

fn removeOverrides(txt: [*c]u8) void {
    while (true) {
        const t = c.strchr(txt, '{');
        if (t == null) break;
        const end = c.strchr(t, '}');
        if (end == null) return;
        _ = c.memmove(t, end + 1, c.strlen(end + 1) + 1);
    }
    for ([_][*:0]const u8{ "\\n", "\\N" }) |pat| {
        while (true) {
            const t = c.strstr(txt, pat);
            if (t == null) break;
            t[0] = ' ';
            t[1] = '\n';
        }
    }
    while (true) {
        const t = c.strstr(txt, "\\h");
        if (t == null) break;
        t[0] = ' ';
        t[1] = ' ';
    }
}

fn pushLine(s: *Self, txt: [*c]u8, start: u64, duration: u64) c.GstFlowReturn {
    var t = txt;
    for (0..8) |_| {
        t = c.strchr(t, ',');
        if (t == null) return c.GST_FLOW_ERROR;
        t += 1;
    }
    removeOverrides(t);
    const escaped = c.g_markup_printf_escaped("%s", t);
    const len = c.strlen(escaped);
    const b = c.gst_buffer_new_allocate(null, len + 1, null);
    _ = c.gst_buffer_fill(b, 0, escaped, len + 1);
    c.gst_buffer_set_size(b, @intCast(len));
    c.g_free(escaped);
    cm.buf(b).pts = start;
    cm.buf(b).duration = duration;
    return c.gst_pad_push(s.srcpad, b);
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(par);
    if (s.framed == 0) {
        cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Only SSA subtitles embedded in containers are supported"), FILE, "gst_ssa_parse_chain", 424);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (s.send_tags != 0) {
        const tags = c.gst_tag_list_new_empty();
        c.gst_tag_list_add(tags, c.GST_TAG_MERGE_APPEND, c.GST_TAG_SUBTITLE_CODEC, "SubStation Alpha", @as(?*anyopaque, null));
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_tag(tags));
        s.send_tags = 0;
    }
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    const txt = c.g_strndup(map.data, map.size);
    c.gst_buffer_unmap(b, &map);
    if (txt == null) {
        cm.elementWarning(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_FORMAT, null, c.g_strdup("Received empty subtitle"), FILE, "gst_ssa_parse_chain", 431);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_OK;
    }
    const ts = cm.buf(b).pts;
    var ret = pushLine(s, txt, ts, cm.buf(b).duration);
    if (ret != c.GST_FLOW_OK and ts != cm.CLOCK_NONE) {
        var seg: c.GstSegment = undefined;
        c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
        seg.start = ts;
        seg.time = ts;
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_segment(&seg));
        ret = c.GST_FLOW_OK;
    }
    c.gst_buffer_unref(b);
    c.g_free(txt);
    return ret;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    const ret = parent.?.change_state.?(el, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        c.g_free(s.ini);
        s.ini = null;
        s.framed = 0;
    }
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).dispose = dispose;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "SSA Subtitle Parser", "Codec/Decoder/Subtitle", "Parses SSA subtitle streams", "Tim-Philipp Müller <tim centricular net>");
    _ = c._gst_debug_category_new("ssaparse", 0, "SSA subtitle parser");
    ec.change_state = changeState;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    c.gst_pad_use_fixed_caps(s.srcpad);
    s.ini = null;
    s.framed = 0;
    s.send_tags = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstSsaParse", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    dt.elementInit(p);
    return c.gst_element_register(p, "ssaparse", c.GST_RANK_PRIMARY, getType()) != 0;
}
