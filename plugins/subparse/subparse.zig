const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const dt = @import("detect.zig");
const fm = @import("formats.zig");
const sami = @import("sami.zig");
const qt = @import("qttext.zig");

const FILE = "../gst/subparse/gstsubparse.c";
const PROP_ENCODING = 1;
const PROP_VIDEOFPS = 2;

const Self = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    adapter: ?*c.GstAdapter,
    textbuf: [*c]c.GString,
    parser_type: c_int,
    subtitle_codec: [*c]const u8,
    parse_line: ?*const anyopaque,
    state: *fm.State,
    offset: u64,
    segment_seqnum: u32,
    segment: c.GstSegment,
    need_segment: c.gboolean,
    flushing: c.gboolean,
    valid_utf8: c.gboolean,
    detected_encoding: [*c]u8,
    encoding: [*c]u8,
    strip_pango_markup: c.gboolean,
    first_buffer: c.gboolean,
    fps_n: c.gint,
    fps_d: c.gint,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-subtitle; application/x-subtitle-sami; application/x-subtitle-tmplayer; application/x-subtitle-mpl2; application/x-subtitle-dks; application/x-subtitle-qttext;application/x-subtitle-lrc; application/x-subtitle-vtt");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "text/x-raw, format= { pango-markup, utf8 }");
var once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn parser(s: *Self) fm.Parser {
    return @ptrCast(s.parse_line.?);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    c.g_free(s.encoding);
    s.encoding = null;
    c.g_free(s.detected_encoding);
    s.detected_encoding = null;
    if (s.adapter) |a| c.g_object_unref(a);
    s.adapter = null;
    if (s.textbuf != null) _ = c.g_string_free(s.textbuf, 1);
    s.textbuf = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    std.heap.c_allocator.destroy(me(o).state);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn srcQuery(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var fmt: c.GstFormat = 0;
            c.gst_query_parse_position(q, &fmt, null);
            if (fmt != c.GST_FORMAT_TIME) return c.gst_pad_peer_query(s.sinkpad, q);
            c.gst_query_set_position(q, c.GST_FORMAT_TIME, @bitCast(s.segment.position));
            return 1;
        },
        c.GST_QUERY_SEEKING => {
            var fmt: c.GstFormat = 0;
            var seekable: c.gboolean = 0;
            c.gst_query_parse_seeking(q, &fmt, null, null, null);
            if (fmt == c.GST_FORMAT_TIME) {
                const peer = c.gst_query_new_seeking(c.GST_FORMAT_BYTES);
                seekable = c.gst_pad_peer_query(s.sinkpad, peer);
                if (seekable != 0) c.gst_query_parse_seeking(peer, null, &seekable, null, null);
                c.gst_query_unref(peer);
            }
            c.gst_query_set_seeking(q, fmt, seekable, if (seekable != 0) 0 else -1, -1);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

fn srcEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    if (cm.eventType(e) != c.GST_EVENT_SEEK) return c.gst_pad_event_default(pad, par, e);
    var rate: f64 = 0;
    var format: c.GstFormat = 0;
    var flags: c.GstSeekFlags = 0;
    var st: c.GstSeekType = 0;
    var sp: c.GstSeekType = 0;
    var start: i64 = 0;
    var stop: i64 = 0;
    c.gst_event_parse_seek(e, &rate, &format, &flags, &st, &start, &sp, &stop);
    if (format != c.GST_FORMAT_TIME) {
        c.gst_event_unref(e);
        return 0;
    }
    if (c.gst_pad_event_default(pad, par, e) != 0) return 1;
    const ok = c.gst_pad_push_event(s.sinkpad, c.gst_event_new_seek(rate, c.GST_FORMAT_BYTES, flags, c.GST_SEEK_TYPE_SET, 0, c.GST_SEEK_TYPE_NONE, 0));
    if (ok != 0) {
        var update: c.gboolean = 0;
        _ = c.gst_segment_do_seek(&s.segment, rate, format, flags, st, @bitCast(start), sp, @bitCast(stop), &update);
    }
    return ok;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_ENCODING => {
            c.g_free(s.encoding);
            s.encoding = c.g_value_dup_string(v);
        },
        PROP_VIDEOFPS => {
            s.fps_n = c.gst_value_get_fraction_numerator(v);
            s.fps_d = c.gst_value_get_fraction_denominator(v);
            if (!s.state.have_internal_fps) {
                s.state.fps_n = s.fps_n;
                s.state.fps_d = s.fps_d;
            }
        },
        else => cm.warnInvalid(FILE, o, id, spec, 340),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    cm.lock(s);
    defer cm.unlock(s);
    switch (id) {
        PROP_ENCODING => c.g_value_set_string(v, s.encoding),
        PROP_VIDEOFPS => c.gst_value_set_fraction(v, s.fps_n, s.fps_d),
        else => cm.warnInvalid(FILE, o, id, spec, 361),
    }
}

fn description(f: c_int) [*c]const u8 {
    return switch (f) {
        dt.MDVDSUB => "MicroDVD",
        dt.SUBRIP => "SubRip",
        dt.MPSUB => "MPSub",
        dt.SAMI => "SAMI",
        dt.TMPLAYER => "TMPlayer",
        dt.MPL2 => "MPL2",
        dt.SUBVIEWER => "SubViewer",
        dt.DKS => "DKS",
        dt.VTT => "WebVTT",
        dt.QTTEXT => "QTtext",
        dt.LRC => "LRC",
        else => null,
    };
}

fn convertEncoding(s: *Self, str: [*c]const u8, len: usize, consumed: *usize) [*c]u8 {
    consumed.* = 0;
    var err: [*c]c.GError = null;
    if (s.detected_encoding != null) {
        const ret = dt.toUtf8(str, len, s.detected_encoding, consumed, &err);
        if (err == null) return ret;
        c.g_free(s.detected_encoding);
        s.detected_encoding = null;
        c.g_clear_error(&err);
    }
    if (s.valid_utf8 != 0) {
        if (c.g_utf8_validate(str, @intCast(len), null) != 0) {
            consumed.* = len;
            return c.g_strndup(str, len);
        }
        s.valid_utf8 = 0;
    }
    var enc: [*c]const u8 = s.encoding;
    if (enc == null or enc[0] == 0) enc = c.g_getenv("GST_SUBTITLE_ENCODING");
    if (enc == null or enc[0] == 0) {
        if (c.g_get_charset(&enc) != 0) enc = "ISO-8859-15";
    }
    var ret = dt.toUtf8(str, len, enc, consumed, &err);
    if (err != null) {
        c.g_clear_error(&err);
        ret = dt.toUtf8(str, len, "ISO-8859-15", consumed, null);
    }
    return ret;
}

fn nextLine(s: *Self) [*c]u8 {
    const str = s.textbuf.*.str;
    var end = c.strchr(str, '\n');
    if (end == null) return null;
    var have_r = false;
    if (end != str and (end - 1)[0] == '\r') {
        end -= 1;
        have_r = true;
    }
    const len = @intFromPtr(end) - @intFromPtr(str);
    const line = c.g_strndup(str, len);
    s.textbuf = c.g_string_erase(s.textbuf, 0, @intCast(len + @as(usize, if (have_r) 2 else 1)));
    return line;
}

fn stateInit(st: *fm.State) void {
    if (st.buf != null) {
        _ = c.g_string_truncate(st.buf, 0);
    } else st.buf = c.g_string_new(null);
    st.start_time = 0;
    st.duration = 0;
    st.max_duration = 0;
    st.state = 0;
    st.segment = null;
}

fn stateDispose(s: *Self, st: *fm.State) void {
    if (st.buf != null) _ = c.g_string_free(st.buf, 1);
    st.buf = null;
    c.g_free(st.vertical);
    st.vertical = null;
    c.g_free(st.alignment);
    st.alignment = null;
    if (st.user_data != null) {
        switch (s.parser_type) {
            dt.QTTEXT => qt.deinit(st),
            dt.SAMI => sami.deinit(st),
            else => {},
        }
    }
    st.allowed_tags = null;
}

fn textCaps(format: [*c]const u8) [*c]c.GstCaps {
    return c.gst_caps_new_simple("text/x-raw", "format", c.G_TYPE_STRING, format, @as(?*anyopaque, null));
}

fn formatAutodetect(s: *Self) [*c]c.GstCaps {
    if (c.strlen(s.textbuf.*.str) < 6) return null;
    const data = c.g_strndup(s.textbuf.*.str, 35);
    const format = dt.autodetect(data);
    c.g_free(data);
    s.parser_type = format;
    s.subtitle_codec = description(format);
    const st = s.state;
    stateInit(st);
    st.allowed_tags = null;
    const set = struct {
        fn f(x: *Self, p: fm.Parser) void {
            x.parse_line = @ptrCast(p);
        }
    }.f;
    switch (format) {
        dt.MDVDSUB => {
            set(s, fm.mdvdsub);
            return textCaps("pango-markup");
        },
        dt.SUBRIP => {
            st.allowed_tags = &fm.srt_tags;
            st.allows_tag_attributes = false;
            set(s, fm.subrip);
            return textCaps("pango-markup");
        },
        dt.MPSUB => {
            set(s, fm.mpsub);
            return textCaps("utf8");
        },
        dt.SAMI => {
            set(s, sami.parse);
            sami.init(st);
            return textCaps("pango-markup");
        },
        dt.TMPLAYER => {
            set(s, fm.tmplayer);
            st.max_duration = 5 * c.GST_SECOND;
            return textCaps("utf8");
        },
        dt.MPL2 => {
            set(s, fm.mpl2);
            return textCaps("pango-markup");
        },
        dt.DKS => {
            set(s, fm.dks);
            return textCaps("utf8");
        },
        dt.VTT => {
            st.allowed_tags = &fm.vtt_tags;
            st.allows_tag_attributes = true;
            set(s, fm.webvtt);
            return textCaps("pango-markup");
        },
        dt.SUBVIEWER => {
            set(s, fm.subviewer);
            return textCaps("utf8");
        },
        dt.QTTEXT => {
            set(s, qt.parse);
            qt.init(st);
            return textCaps("pango-markup");
        },
        dt.LRC => {
            set(s, fm.lrc);
            return textCaps("utf8");
        },
        else => {
            cm.elementError(s, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_WRONG_TYPE, c.g_strdup("The input is not a valid/supported subtitle file"), null, FILE, "gst_sub_parse_format_autodetect", 1574);
            return null;
        },
    }
}

fn feed(s: *Self, b: [*c]c.GstBuffer) void {
    var discont = @as(*c.GstMiniObject, @ptrCast(b)).flags & c.GST_BUFFER_FLAG_DISCONT != 0;
    const boff = cm.buf(b).offset;
    if (boff != cm.CLOCK_NONE and boff != s.offset) {
        s.offset = boff;
        discont = true;
    }
    if (discont) {
        stateInit(s.state);
        _ = c.g_string_truncate(s.textbuf, 0);
        c.gst_adapter_clear(s.adapter);
        if (s.parser_type == dt.SAMI) sami.reset(s.state);
    }
    s.offset +%= c.gst_buffer_get_size(b);
    c.gst_adapter_push(s.adapter, b);
    const avail = c.gst_adapter_available(s.adapter);
    const data: [*c]const u8 = @ptrCast(c.gst_adapter_map(s.adapter, avail));
    var consumed: usize = 0;
    const input = convertEncoding(s, data, avail, &consumed);
    if (input != null and consumed > 0) {
        s.textbuf = c.g_string_append(s.textbuf, input);
        c.gst_adapter_unmap(s.adapter);
        c.gst_adapter_flush(s.adapter, consumed);
    } else c.gst_adapter_unmap(s.adapter);
    c.g_free(input);
}

fn xmlText(_: ?*c.GMarkupParseContext, t: [*c]const u8, _: usize, data: c.gpointer, _: [*c][*c]c.GError) callconv(.c) void {
    const acc: *[*c]u8 = @ptrCast(@alignCast(data));
    if (acc.* != null) {
        const cat = c.g_strconcat(acc.*, t, @as(?*anyopaque, null));
        c.g_free(acc.*);
        acc.* = cat;
    } else acc.* = c.g_strdup(t);
}

fn stripMarkup(markup: [*c]u8, err: *[*c]c.GError) [*c]u8 {
    var p = std.mem.zeroes(c.GMarkupParser);
    p.text = xmlText;
    var acc: [*c]u8 = null;
    const ctx = c.g_markup_parse_context_new(&p, 0, @ptrCast(&acc), null);
    defer c.g_markup_parse_context_free(ctx);
    _ = c.g_markup_parse_context_parse(ctx, "<root>", 6, null);
    _ = c.g_markup_parse_context_parse(ctx, markup, @intCast(c.strlen(markup)), err);
    _ = c.g_markup_parse_context_parse(ctx, "</root>", 7, null);
    if (err.* == null) _ = c.g_markup_parse_context_end_parse(ctx, err);
    if (err.* != null) {
        c.g_free(acc);
        return null;
    }
    return acc;
}

fn negotiate(s: *Self, preferred: [*c]c.GstCaps) bool {
    var caps = c.gst_pad_get_allowed_caps(s.srcpad);
    const s1 = c.gst_caps_get_structure(preferred, 0);
    if (c.g_strcmp0(c.gst_structure_get_string(s1, "format"), "utf8") == 0) {
        const inter = c.gst_caps_intersect(caps, preferred);
        c.gst_caps_unref(caps);
        caps = inter;
    }
    caps = c.gst_caps_fixate(caps);
    defer c.gst_caps_unref(caps);
    if (c.gst_caps_is_empty(caps) != 0) return false;
    const s2 = c.gst_caps_get_structure(caps, 0);
    s.strip_pango_markup = @intFromBool(c.g_strcmp0(c.gst_structure_get_string(s2, "format"), "utf8") == 0 and c.g_strcmp0(c.gst_structure_get_string(s1, "format"), "pango-markup") == 0);
    return cm.setCaps(s.srcpad, caps);
}

fn initialEvents(s: *Self) c.GstFlowReturn {
    var need_tags = false;
    if (s.parser_type == dt.UNKNOWN) {
        const preferred = formatAutodetect(s);
        if (preferred == null) return c.GST_FLOW_NOT_NEGOTIATED;
        defer c.gst_caps_unref(preferred);
        if (!negotiate(s, preferred)) return c.GST_FLOW_NOT_NEGOTIATED;
        need_tags = true;
    }
    if (s.need_segment != 0) {
        const ev = c.gst_event_new_segment(&s.segment);
        c.gst_event_set_seqnum(ev, s.segment_seqnum);
        _ = c.gst_pad_push_event(s.srcpad, ev);
        s.need_segment = 0;
    }
    if (need_tags and s.subtitle_codec != null) {
        const tags = c.gst_tag_list_new(c.GST_TAG_SUBTITLE_CODEC, s.subtitle_codec, @as(?*anyopaque, null));
        _ = c.gst_pad_push_event(s.srcpad, c.gst_event_new_tag(tags));
    }
    return c.GST_FLOW_OK;
}

fn handleBuffer(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const st = s.state;
    if (s.first_buffer != 0) {
        var map: c.GstMapInfo = undefined;
        _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
        s.detected_encoding = dt.detectEncoding(map.data, map.size);
        c.gst_buffer_unmap(b, &map);
        s.first_buffer = 0;
        st.fps_n = s.fps_n;
        st.fps_d = s.fps_d;
    }
    feed(s, b);
    var ret = initialEvents(s);
    if (ret != c.GST_FLOW_OK) return ret;
    while (s.flushing == 0) {
        const line = nextLine(s);
        if (line == null) break;
        st.segment = &s.segment;
        var sub = parser(s)(st, line);
        c.g_free(line);
        if (sub == null) continue;
        if (s.strip_pango_markup != 0) {
            var err: [*c]c.GError = null;
            const stripped = stripMarkup(sub, &err);
            if (stripped != null) {
                c.g_free(sub);
                sub = stripped;
            }
        }
        const len = c.strlen(sub);
        const out = c.gst_buffer_new_allocate(null, len + 1, null);
        _ = c.gst_buffer_fill(out, 0, sub, len + 1);
        c.gst_buffer_set_size(out, @intCast(len));
        cm.buf(out).pts = st.start_time;
        cm.buf(out).duration = st.duration;
        if (st.max_duration > 0 and st.duration != cm.CLOCK_NONE and st.duration > st.max_duration) cm.buf(out).duration = st.max_duration;
        s.segment.position = st.start_time;
        c.g_free(st.vertical);
        st.vertical = null;
        c.g_free(st.alignment);
        st.alignment = null;
        ret = c.gst_pad_push(s.srcpad, out);
        if (st.duration != cm.CLOCK_NONE) st.start_time +%= st.duration;
        c.g_free(sub);
        if (ret != c.GST_FLOW_OK) break;
    }
    return ret;
}

fn chain(_: ?*c.GstPad, par: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return handleBuffer(me(par), b);
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const s = me(par);
    switch (cm.eventType(e)) {
        c.GST_EVENT_STREAM_GROUP_DONE, c.GST_EVENT_EOS => {
            switch (s.parser_type) {
                dt.SUBRIP, dt.TMPLAYER, dt.MPL2, dt.QTTEXT, dt.VTT => {
                    const b = c.gst_buffer_new_allocate(null, 3, null);
                    _ = c.gst_buffer_fill(b, 0, "\n\n", 3);
                    c.gst_buffer_set_size(b, 2);
                    cm.buf(b).offset = s.offset;
                    _ = chain(pad, par, b);
                },
                else => {},
            }
            return c.gst_pad_event_default(pad, par, e);
        },
        c.GST_EVENT_SEGMENT => {
            var seg: [*c]const c.GstSegment = null;
            c.gst_event_parse_segment(e, &seg);
            if (seg.*.format == c.GST_FORMAT_TIME) c.gst_event_copy_segment(e, &s.segment);
            s.segment_seqnum = c.gst_event_get_seqnum(e);
            c.gst_event_unref(e);
            s.need_segment = 1;
            return 1;
        },
        c.GST_EVENT_GAP => {
            if (initialEvents(s) == c.GST_FLOW_OK) return c.gst_pad_event_default(pad, par, e);
            c.gst_event_unref(e);
            return 0;
        },
        c.GST_EVENT_FLUSH_START => {
            s.flushing = 1;
            return c.gst_pad_event_default(pad, par, e);
        },
        c.GST_EVENT_FLUSH_STOP => {
            s.flushing = 0;
            return c.gst_pad_event_default(pad, par, e);
        },
        else => return c.gst_pad_event_default(pad, par, e),
    }
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(el);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        s.offset = 0;
        s.parser_type = dt.UNKNOWN;
        s.strip_pango_markup = 0;
        s.valid_utf8 = 1;
        s.first_buffer = 1;
        c.g_free(s.detected_encoding);
        s.detected_encoding = null;
        _ = c.g_string_truncate(s.textbuf, 0);
        c.gst_adapter_clear(s.adapter);
    }
    const ret = parent.?.change_state.?(el, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        stateDispose(s, s.state);
        s.parser_type = dt.UNKNOWN;
    }
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = dispose;
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "Subtitle parser", "Codec/Decoder/Subtitle", "Parses subtitle (.sub) files into text streams", "Gustavo J. A. M. Carneiro <gjc@inescporto.pt>, GStreamer maintainers <gstreamer-devel@lists.freedesktop.org>");
    ec.change_state = changeState;
    c.g_object_class_install_property(oc, PROP_ENCODING, c.g_param_spec_string("subtitle-encoding", "subtitle charset encoding", "Encoding to assume if input subtitles are not in UTF-8 or any other Unicode encoding. If not set, the GST_SUBTITLE_ENCODING environment variable will be checked for an encoding to use. If that is not set either, ISO-8859-15 will be assumed.", null, cm.RW));
    c.g_object_class_install_property(oc, PROP_VIDEOFPS, c.gst_param_spec_fraction("video-fps", "Video framerate", "Framerate of the video stream. This is needed by some subtitle formats to synchronize subtitles and video properly. If not set and the subtitle format requires it subtitles may be out of sync.", 0, 1, std.math.maxInt(c.gint), 1, 24000, 1001, cm.RW));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sinkpad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(s.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
    s.srcpad = c.gst_pad_new_from_static_template(&src_t, "src");
    c.gst_pad_set_event_function_full(s.srcpad, srcEvent, null, null);
    c.gst_pad_set_query_function_full(s.srcpad, srcQuery, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
    s.state = std.heap.c_allocator.create(fm.State) catch unreachable;
    s.state.* = .{};
    s.textbuf = c.g_string_new(null);
    s.parser_type = dt.UNKNOWN;
    s.strip_pango_markup = 0;
    s.flushing = 0;
    c.gst_segment_init(&s.segment, c.GST_FORMAT_TIME);
    s.segment_seqnum = c.gst_util_seqnum_next();
    s.need_segment = 1;
    s.encoding = null;
    s.detected_encoding = null;
    s.adapter = c.gst_adapter_new();
    s.fps_n = 24000;
    s.fps_d = 1001;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstSubParse", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    dt.elementInit(p);
    return c.gst_element_register(p, "subparse", c.GST_RANK_PRIMARY, getType()) != 0;
}
