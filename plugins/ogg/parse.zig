const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const os = @import("stream.zig");

const NONE = cm.CLOCK_NONE;
const SECOND: u64 = 1_000_000_000;

const OggParse = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    oggstreams: [*c]c.GSList,
    offset: i64,
    in_headers: c.gboolean,
    last_page_not_bos: c.gboolean,
    sync: c.ogg_sync_state,
    caps: [*c]c.GstCaps,
    video_stream: ?*os.Stream,
};

const ElementClass = extern struct {
    parent: c.GstElementClass,
};

var op_src = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "application/ogg");
var op_sink = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/ogg");
var op_once: cm.Once = .{};
var op_parent: ?*c.GstElementClass = null;

fn unrefAll(l: [*c]c.GList) void {
    var w = l;
    while (w != null) : (w = w.*.next) c.gst_mini_object_unref(@ptrCast(@alignCast(w.*.data)));
}

fn freeStream(s: *os.Stream) void {
    unrefAll(s.headers);
    unrefAll(s.unknown_pages);
    unrefAll(s.stored_buffers);
    c.g_free(s);
}

fn deleteStreams(o: *OggParse) void {
    var l = o.oggstreams;
    while (l != null) : (l = l.*.next) freeStream(@ptrCast(@alignCast(l.*.data)));
    c.g_slist_free(o.oggstreams);
    o.oggstreams = null;
}

fn newStream(o: *OggParse, page: *c.ogg_page) ?*os.Stream {
    const serial: u32 = @bitCast(c.ogg_page_serialno(page));
    const s: *os.Stream = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(os.Stream))));
    s.serialno = serial;
    s.in_headers = 1;
    if (c.ogg_stream_init(&s.stream, @bitCast(serial)) != 0 or c.ogg_stream_pagein(&s.stream, page) != 0) {
        freeStream(s);
        return null;
    }
    var pk: os.Packet = undefined;
    if (c.ogg_stream_packetout(&s.stream, &pk) == 1) {
        if (!os.setupMap(s, &pk)) {
            freeStream(s);
            return null;
        }
        if (s.is_video != 0) o.video_stream = s;
    }
    o.oggstreams = c.g_slist_append(o.oggstreams, s);
    return s;
}

fn findStream(o: *OggParse, serial: u32) ?*os.Stream {
    var l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        if (s.serialno == serial) return s;
    }
    return null;
}

fn opDispose(ob: [*c]c.GObject) callconv(.c) void {
    const o: *OggParse = @ptrCast(@alignCast(ob));
    _ = c.ogg_sync_clear(&o.sync);
    deleteStreams(o);
    if (o.caps != null) c.gst_caps_unref(o.caps);
    o.caps = null;
    const gc: *c.GObjectClass = @ptrCast(op_parent.?);
    if (gc.dispose) |d| d(ob);
}

fn appendHeader(arr: *c.GValue, b: [*c]c.GstBuffer) void {
    const copy = c.gst_buffer_copy(b);
    cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_HEADER;
    var v = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&v, c.gst_buffer_get_type());
    c.gst_value_set_buffer(&v, copy);
    c.gst_value_array_append_value(arr, &v);
    c.g_value_unset(&v);
}

fn bufferFromPage(page: *c.ogg_page, offset: u64, ts: u64) [*c]c.GstBuffer {
    const size: usize = @intCast(page.header_len + page.body_len);
    const b = c.gst_buffer_new_allocate(null, size, null);
    _ = c.gst_buffer_fill(b, 0, page.header, @intCast(page.header_len));
    _ = c.gst_buffer_fill(b, @intCast(page.header_len), page.body, @intCast(page.body_len));
    cm.buf(b).pts = ts;
    cm.buf(b).offset = offset;
    cm.buf(b).offset_end = offset +% size;
    return b;
}

fn opFail(o: *OggParse) c.GstFlowReturn {
    _ = c.gst_pad_push_event(o.srcpad, c.gst_event_new_eos());
    return c.GST_FLOW_ERROR;
}

fn opSubmit(o: *OggParse, b: [*c]c.GstBuffer) void {
    defer c.gst_buffer_unref(b);
    var size = c.gst_buffer_get_size(b);
    if (size == 0) return;
    const ob = c.ogg_sync_buffer(&o.sync, @intCast(size));
    if (ob == null) {
        cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("failed to get ogg sync buffer"), "../ext/ogg/gstoggparse.c", "gst_ogg_parse_submit_buffer", 281);
        return;
    }
    size = c.gst_buffer_extract(b, 0, ob, size);
    if (c.ogg_sync_wrote(&o.sync, @intCast(size)) < 0) cm.elementError(o, c.gst_stream_error_quark(), c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("failed to write %lu bytes to the sync buffer", size), "../ext/ogg/gstoggparse.c", "gst_ogg_parse_submit_buffer", 289);
}

fn pushHeaders(o: *OggParse) c.GstFlowReturn {
    var arr = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&arr, c.gst_value_array_get_type());
    var l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        if (c.g_list_length(s.headers) == 0) return opFail(o);
        appendHeader(&arr, @ptrCast(@alignCast(s.headers.*.data)));
    }
    l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        var j = s.headers.*.next;
        while (j != null) : (j = j.*.next) appendHeader(&arr, @ptrCast(@alignCast(j.*.data)));
    }
    var caps = c.gst_pad_query_caps(o.srcpad, null);
    caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
    c.gst_structure_take_value(c.gst_caps_get_structure(caps, 0), "streamheader", &arr);
    _ = cm.setCaps(o.srcpad, caps);
    if (o.caps != null) c.gst_caps_unref(o.caps);
    o.caps = caps;
    l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        const r = c.gst_pad_push(o.srcpad, @ptrCast(@alignCast(s.headers.*.data)));
        if (r != c.GST_FLOW_OK) return r;
    }
    l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        var j = s.headers.*.next;
        while (j != null) : (j = j.*.next) {
            const r = c.gst_pad_push(o.srcpad, @ptrCast(@alignCast(j.*.data)));
            if (r != c.GST_FLOW_OK) return r;
        }
    }
    o.in_headers = 0;
    l = o.oggstreams;
    while (l != null) : (l = l.*.next) {
        const s: *os.Stream = @ptrCast(@alignCast(l.*.data));
        if (s.unknown_pages == null) continue;
        var k = s.unknown_pages;
        while (k != null) : (k = k.*.next) {
            const r = c.gst_pad_push(o.srcpad, @ptrCast(@alignCast(k.*.data)));
            if (r != c.GST_FLOW_OK) return r;
        }
        unrefAll(s.unknown_pages);
        c.g_list_free(s.unknown_pages);
        s.unknown_pages = null;
    }
    return c.GST_FLOW_OK;
}

fn opChain(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const o: *OggParse = @ptrCast(@alignCast(parent));
    var result: c.GstFlowReturn = c.GST_FLOW_OK;
    var ts = cm.buf(b).pts;
    opSubmit(o, b);
    var r: c_long = -1;
    while (r != 0 and result == c.GST_FLOW_OK) {
        var page: c.ogg_page = undefined;
        r = c.ogg_sync_pageseek(&o.sync, &page);
        if (r == 0) break;
        if (r < 0) {
            o.offset -= r;
            continue;
        }
        const granule = c.ogg_page_granulepos(&page);
        const start: u64 = @bitCast(o.offset);
        const serial: u32 = @bitCast(c.ogg_page_serialno(&page));
        var keyframe = true;
        if (findStream(o, serial)) |s| {
            ts = os.endTimeForGranulepos(s, granule);
            if (o.video_stream) |vs| keyframe = if (s == vs) os.granuleposIsKeyFrame(s, granule) else false;
        } else ts = NONE;
        var pb = bufferFromPage(&page, start, ts);
        o.offset += r;
        if (c.ogg_page_bos(&page) != 0) {
            if (o.last_page_not_bos != 0) deleteStreams(o);
            const s = newStream(o, &page) orelse return opFail(o);
            o.last_page_not_bos = 0;
            _ = c.gst_mini_object_ref(@ptrCast(pb));
            s.headers = c.g_list_append(s.headers, pb);
            if (o.in_headers == 0) o.in_headers = 1;
        } else {
            const s = findStream(o, serial) orelse return opFail(o);
            o.last_page_not_bos = 1;
            const kind: u8 = if (granule < 0) 2 else if (granule > 0) 1 else 0;
            if (kind == 2 and o.in_headers != 0) {
                _ = c.gst_mini_object_ref(@ptrCast(pb));
                s.unknown_pages = c.g_list_append(s.unknown_pages, pb);
            } else if (kind == 0) {
                if (o.in_headers == 0) return opFail(o);
                s.headers = c.g_list_concat(s.headers, s.unknown_pages);
                s.unknown_pages = null;
                _ = c.gst_mini_object_ref(@ptrCast(pb));
                s.headers = c.g_list_append(s.headers, pb);
            } else {
                if (o.in_headers != 0) {
                    const hr = pushHeaders(o);
                    if (hr != c.GST_FLOW_OK) return hr;
                }
                if (granule == -1) {
                    s.stored_buffers = c.g_list_append(s.stored_buffers, pb);
                } else {
                    while (s.stored_buffers != null) {
                        var sb: [*c]c.GstBuffer = @ptrCast(@alignCast(s.stored_buffers.*.data));
                        sb = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(sb)));
                        cm.buf(sb).pts = ts;
                        if (!keyframe) {
                            cm.buf(sb).mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
                        } else keyframe = false;
                        const pr = c.gst_pad_push(o.srcpad, sb);
                        if (pr != c.GST_FLOW_OK) return pr;
                        s.stored_buffers = c.g_list_delete_link(s.stored_buffers, s.stored_buffers);
                    }
                    pb = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(pb)));
                    if (!keyframe) cm.buf(pb).mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
                    result = c.gst_pad_push(o.srcpad, pb);
                    if (result != c.GST_FLOW_OK) return result;
                }
            }
        }
    }
    return result;
}

fn opChange(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const o: *OggParse = @ptrCast(@alignCast(el));
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => _ = c.ogg_sync_init(&o.sync),
        c.GST_STATE_CHANGE_READY_TO_PAUSED => _ = c.ogg_sync_reset(&o.sync),
        else => {},
    }
    const r = op_parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) _ = c.ogg_sync_clear(&o.sync);
    return r;
}

fn opClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Ogg parser", "Codec/Parser", "parse ogg streams into pages (info about ogg: http://xiph.org)", "Michael Smith <msmith@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &op_sink);
    c.gst_element_class_add_static_pad_template(ec, &op_src);
    op_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    ec.change_state = opChange;
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.dispose = opDispose;
}

fn opInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o: *OggParse = @ptrCast(@alignCast(inst));
    o.sinkpad = c.gst_pad_new_from_static_template(&op_sink, "sink");
    o.srcpad = c.gst_pad_new_from_static_template(&op_src, "src");
    c.gst_pad_set_chain_function_full(o.sinkpad, opChain, null, null);
    _ = c.gst_element_add_pad(&o.element, o.sinkpad);
    _ = c.gst_element_add_pad(&o.element, o.srcpad);
    o.oggstreams = null;
}

fn opType() c.GType {
    return op_once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstOggParse", ElementClass, OggParse, opClassInit, opInit);
            _ = c._gst_debug_category_new("oggparse", 0, "ogg parser");
            return t;
        }
    }.f);
}

pub fn registerOggParse(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "oggparse", c.GST_RANK_NONE, opType()) != 0;
}

const Header = extern struct {
    streamtype: [8]u8,
    subtype: [5]u8,
    size: i32,
    time_unit: i64,
    samples_per_unit: i64,
    default_len: i32,
    buffersize: i32,
    bits_per_sample: i32,
    a: i32,
    b: i32,
};

const Ogm = extern struct {
    element: c.GstElement,
    srcpad: ?*c.GstPad,
    sinkpad: ?*c.GstPad,
    srcpadtempl: [*c]c.GstPadTemplate,
    cached_events: [*c]c.GList,
    hdr: Header,
    next_granulepos: u64,
};

var ogm_once: cm.Once = .{};
var audio_once: cm.Once = .{};
var video_once: cm.Once = .{};
var text_once: cm.Once = .{};
var ogm_parent: ?*c.GstElementClass = null;
var sink_video = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-ogm-video");
var sink_audio = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-ogm-audio");
var sink_text = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-ogm-text");
var video_src: [*c]c.GstPadTemplate = null;
var audio_src: [*c]c.GstPadTemplate = null;
var text_src: [*c]c.GstPadTemplate = null;
const OGM_FILE = "../ext/ogg/gstogmparse.c";

fn ogmOf(p: anytype) *Ogm {
    return @ptrCast(@alignCast(p));
}

fn le16(d: [*]const u8) i16 {
    return @bitCast(std.mem.readInt(u16, d[0..2], .little));
}

fn le32(d: [*]const u8) i32 {
    return @bitCast(std.mem.readInt(u32, d[0..4], .little));
}

fn le64(d: [*]const u8) i64 {
    return @bitCast(std.mem.readInt(u64, d[0..8], .little));
}

fn convert(o: *Ogm, sf: c.GstFormat, sv: i64, df: *c.GstFormat, dv: *i64) bool {
    const k = o.hdr.streamtype[0];
    if (sf == c.GST_FORMAT_DEFAULT and df.* == c.GST_FORMAT_TIME) {
        if (k == 'a') {
            dv.* = @divTrunc(@as(i64, @intCast(SECOND)) *% sv, o.hdr.samples_per_unit);
            return true;
        }
        if (k == 'v' or k == 't') {
            dv.* = 100 *% o.hdr.time_unit *% sv;
            return true;
        }
    } else if (sf == c.GST_FORMAT_TIME and df.* == c.GST_FORMAT_DEFAULT) {
        if (k == 'a') {
            dv.* = @divTrunc(o.hdr.samples_per_unit *% sv, @as(i64, @intCast(SECOND)));
            return true;
        }
        if (k == 'v' or k == 't') {
            dv.* = @divTrunc(sv, 100 *% o.hdr.time_unit);
            return true;
        }
    }
    return false;
}

fn ogmQuery(pad: ?*c.GstPad, parent: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const o = ogmOf(parent);
    switch (cm.queryType(q)) {
        c.GST_QUERY_POSITION => {
            var f: c.GstFormat = 0;
            c.gst_query_parse_position(q, &f, null);
            if (f != c.GST_FORMAT_DEFAULT and f != c.GST_FORMAT_TIME) return 0;
            var v: i64 = 0;
            if (!convert(o, c.GST_FORMAT_DEFAULT, @bitCast(o.next_granulepos), &f, &v)) return 0;
            c.gst_query_set_position(q, f, v);
            return 1;
        },
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            if (!convert(o, sf, sv, &df, &dv)) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn ogmErr(o: *Ogm, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime func: []const u8, line: c_int) c.GstFlowReturn {
    cm.elementError(o, c.gst_stream_error_quark(), code, text, debug, OGM_FILE, func, line);
    return c.GST_FLOW_ERROR;
}

fn streamHeader(o: *Ogm, d: [*]const u8, size: usize) c.GstFlowReturn {
    const F = "gst_ogm_parse_stream_header";
    if (size < 52) return ogmErr(o, c.GST_STREAM_ERROR_WRONG_TYPE, c.g_strdup("Buffer too small"), null, F, 694);
    if (std.mem.eql(u8, d[0..8], "video\x00\x00\x00")) {
        o.hdr.a = le32(d + 44);
        o.hdr.b = le32(d + 48);
    } else if (std.mem.eql(u8, d[0..8], "audio\x00\x00\x00")) {
        const ch = le32(d + 44);
        const ba = le32(d + 46);
        o.hdr.a = @as(i32, @as(u16, @truncate(@as(u32, @bitCast(ch))))) | (@as(i32, @as(u16, @truncate(@as(u32, @bitCast(ba))))) << 16);
        o.hdr.b = le32(d + 48);
    } else if (!std.mem.eql(u8, d[0..8], "text\x00\x00\x00\x00")) return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("unknown ogm format"), F, 699);
    @memcpy(&o.hdr.streamtype, d[0..8]);
    @memcpy(o.hdr.subtype[0..4], d[8..12]);
    o.hdr.subtype[4] = 0;
    o.hdr.size = le32(d + 12);
    o.hdr.time_unit = le64(d + 16);
    o.hdr.samples_per_unit = le64(d + 24);
    o.hdr.default_len = le32(d + 32);
    o.hdr.buffersize = le32(d + 36);
    o.hdr.bits_per_sample = le32(d + 40);
    var caps: [*c]c.GstCaps = null;
    switch (o.hdr.streamtype[0]) {
        'a' => {
            var codec: c.guint = 0;
            _ = c.sscanf(@ptrCast(&o.hdr.subtype), "%04x", &codec);
            caps = c.gst_riff_create_audio_caps(@truncate(codec), null, null, null, null, null, null);
            if (caps == null) caps = c.gst_caps_new_simple("audio/x-ogm-unknown", "codec_id", c.G_TYPE_INT, @as(c.gint, @bitCast(codec)), @as(?*anyopaque, null));
            const channels: c.gint = @as(i16, @truncate(o.hdr.a));
            c.gst_caps_set_simple(caps, "channels", c.G_TYPE_INT, channels, "rate", c.G_TYPE_INT, @as(c.gint, @truncate(o.hdr.samples_per_unit)), @as(?*anyopaque, null));
        },
        'v' => {
            const st = o.hdr.subtype;
            const fourcc = @as(u32, st[0]) | (@as(u32, st[1]) << 8) | (@as(u32, st[2]) << 16) | (@as(u32, st[3]) << 24);
            caps = c.gst_riff_create_video_caps(fourcc, null, null, null, null, null);
            if (caps == null) {
                const fstr = c.g_strdup_printf("%c%c%c%c", @as(c_int, st[0]), @as(c_int, st[1]), @as(c_int, st[2]), @as(c_int, st[3]));
                caps = c.gst_caps_new_simple("video/x-ogm-unknown", "fourcc", c.G_TYPE_STRING, fstr, @as(?*anyopaque, null));
                c.g_free(fstr);
            } else {
                const tu: c.gint = @intCast(std.math.clamp(o.hdr.time_unit, 1, std.math.maxInt(c.gint)));
                c.gst_caps_set_simple(caps, "width", c.G_TYPE_INT, o.hdr.a, "height", c.G_TYPE_INT, o.hdr.b, "framerate", c.gst_fraction_get_type(), @as(c.gint, 10000000), tu, @as(?*anyopaque, null));
            }
        },
        else => caps = c.gst_caps_new_simple("text/x-raw", "format", c.G_TYPE_STRING, "utf8", @as(?*anyopaque, null)),
    }
    if (caps == null) return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("unknown ogm format"), F, 699);
    if (c.gst_caps_is_fixed(caps) == 0) {
        c.gst_caps_unref(caps);
        return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("broken ogm format"), F, 705);
    }
    if (o.srcpad != null) {
        const cur = c.gst_pad_get_current_caps(o.srcpad);
        if (cur != null) {
            if (c.gst_caps_is_equal(cur, caps) == 0) {
                _ = c.gst_pad_set_active(o.srcpad, 0);
                _ = c.gst_element_remove_pad(&o.element, o.srcpad);
                o.srcpad = null;
            }
            c.gst_caps_unref(cur);
        }
    }
    if (o.srcpad == null) {
        o.srcpad = c.gst_pad_new_from_template(o.srcpadtempl, "src");
        c.gst_pad_use_fixed_caps(o.srcpad);
        _ = c.gst_pad_set_active(o.srcpad, 1);
        _ = c.gst_element_add_pad(&o.element, o.srcpad);
        cm.lock(o);
        const cached = o.cached_events;
        o.cached_events = null;
        cm.unlock(o);
        var l = cached;
        while (l != null) : (l = l.*.next) _ = c.gst_pad_push_event(o.srcpad, @ptrCast(@alignCast(l.*.data)));
        c.g_list_free(cached);
        _ = cm.setCaps(o.srcpad, caps);
        const tags = c.gst_tag_list_new("subtitle-codec", @as([*:0]const u8, "Ogm"), @as(?*anyopaque, null));
        _ = c.gst_pad_push_event(o.srcpad, c.gst_event_new_tag(tags));
    }
    c.gst_caps_unref(caps);
    return c.GST_FLOW_OK;
}

fn commentPacket(o: *Ogm, b: [*c]c.GstBuffer) c.GstFlowReturn {
    if (o.srcpad == null) return c.GST_FLOW_FLUSHING;
    if (o.hdr.streamtype[0] == 't') {
        const tags = c.gst_tag_list_from_vorbiscomment_buffer(b, "\x03vorbis", 7, null);
        if (tags != null) _ = c.gst_pad_push_event(o.srcpad, c.gst_event_new_tag(tags));
        return c.GST_FLOW_OK;
    }
    _ = c.gst_mini_object_ref(@ptrCast(b));
    return c.gst_pad_push(o.srcpad, b);
}

fn dataPacket(o: *Ogm, b: [*c]c.GstBuffer, d: [*]const u8, size: usize) c.GstFlowReturn {
    const F = "gst_ogm_parse_data_packet";
    if (d[0] & 1 != 0) return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("unexpected packet startcode 0x%02x", @as(c_uint, d[0])), F, 860);
    const len: usize = ((d[0] & 0xc0) >> 6) | ((d[0] & 0x02) << 1);
    const keyframe = (d[0] & 0x08) >> 3 != 0;
    if (1 + len > size) return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup_printf("buffer too small, len+1=%u, size=%lu", @as(c_uint, @intCast(len + 1)), size), F, 866);
    var xsize: u32 = 0;
    var n = len;
    while (n > 0) : (n -= 1) xsize = (xsize << 8) | d[n];
    const sb = c.gst_buffer_copy_region(b, c.GST_BUFFER_COPY_ALL, len + 1, size - len - 1);
    if (cm.buf(b).offset_end != NONE) o.next_granulepos = cm.buf(b).offset_end;
    switch (o.hdr.streamtype[0]) {
        't', 'v' => {
            const samples: u64 = if (o.hdr.streamtype[0] == 'v') 1 else xsize;
            if (!keyframe) cm.buf(sb).mini_object.flags |= c.GST_BUFFER_FLAG_DELTA_UNIT;
            const unit = @as(u64, @bitCast(o.hdr.time_unit)) *% SECOND;
            const ts = c.gst_util_uint64_scale(o.next_granulepos, unit, 10000000);
            const next = c.gst_util_uint64_scale(o.next_granulepos +% samples, unit, 10000000);
            cm.buf(sb).pts = ts;
            cm.buf(sb).duration = next -% ts;
            o.next_granulepos +%= samples;
        },
        else => {
            const spu: c.gint = @truncate(o.hdr.samples_per_unit);
            const ts = c.gst_util_uint64_scale_int(o.next_granulepos, SECOND, spu);
            const next = c.gst_util_uint64_scale_int(o.next_granulepos +% xsize, SECOND, spu);
            cm.buf(sb).pts = ts;
            cm.buf(sb).duration = next -% ts;
            o.next_granulepos +%= xsize;
        },
    }
    if (o.srcpad != null) return c.gst_pad_push(o.srcpad, sb);
    c.gst_buffer_unref(sb);
    return c.GST_FLOW_FLUSHING;
}

fn ogmChain(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const o = ogmOf(parent);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer {
        c.gst_buffer_unmap(b, &map);
        c.gst_buffer_unref(b);
    }
    if (map.size < 1) return ogmErr(o, c.GST_STREAM_ERROR_DECODE, null, c.g_strdup("buffer too small"), "gst_ogm_parse_chain", 911);
    return switch (map.data[0]) {
        0x01 => streamHeader(o, map.data + 1, map.size - 1),
        0x03 => commentPacket(o, b),
        else => dataPacket(o, b, map.data, map.size),
    };
}

fn ogmEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const o = ogmOf(parent);
    cm.lock(o);
    if (o.srcpad == null) {
        o.cached_events = c.g_list_append(o.cached_events, ev);
        cm.unlock(o);
        return 1;
    }
    cm.unlock(o);
    return c.gst_pad_event_default(pad, parent, ev);
}

fn ogmChange(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const o = ogmOf(el);
    const r = ogm_parent.?.change_state.?(el, t);
    if (r != c.GST_STATE_CHANGE_SUCCESS) return r;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        if (o.srcpad != null) {
            _ = c.gst_pad_set_active(o.srcpad, 0);
            _ = c.gst_element_remove_pad(el, o.srcpad);
            o.srcpad = null;
        }
        o.hdr = std.mem.zeroes(Header);
        o.next_granulepos = 0;
        unrefAll(o.cached_events);
        c.g_list_free(o.cached_events);
        o.cached_events = null;
    }
    return r;
}

fn ogmClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    ogm_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = ogmChange;
    c.gst_type_mark_as_plugin_api(ogmType(), 0);
}

fn ogmInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o = ogmOf(inst);
    o.hdr = std.mem.zeroes(Header);
    o.next_granulepos = 0;
    o.srcpad = null;
    o.cached_events = null;
}

fn ogmType() c.GType {
    return ogm_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_element_get_type(), "GstOgmParse", ElementClass, Ogm, ogmClassInit, ogmInit);
        }
    }.f);
}

fn subInit(o: *Ogm, sink: *c.GstStaticPadTemplate, src: [*c]c.GstPadTemplate) void {
    o.sinkpad = c.gst_pad_new_from_static_template(sink, "sink");
    c.gst_pad_set_query_function_full(o.sinkpad, ogmQuery, null, null);
    c.gst_pad_set_chain_function_full(o.sinkpad, ogmChain, null, null);
    c.gst_pad_set_event_function_full(o.sinkpad, ogmEvent, null, null);
    _ = c.gst_element_add_pad(&o.element, o.sinkpad);
    o.srcpad = null;
    o.srcpadtempl = src;
}

fn audioBase(k: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const caps = c.gst_riff_create_audio_template_caps();
    c.gst_element_class_set_static_metadata(ec, "OGM audio stream parser", "Codec/Parser/Audio", "parse an OGM audio header and stream", "GStreamer maintainers <gstreamer-devel@lists.freedesktop.org>");
    c.gst_element_class_add_static_pad_template(ec, &sink_audio);
    audio_src = c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, caps);
    c.gst_element_class_add_pad_template(ec, audio_src);
    c.gst_caps_unref(caps);
}

fn videoBase(k: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const caps = c.gst_riff_create_video_template_caps();
    c.gst_element_class_set_static_metadata(ec, "OGM video stream parser", "Codec/Parser/Video", "parse an OGM video header and stream", "GStreamer maintainers <gstreamer-devel@lists.freedesktop.org>");
    c.gst_element_class_add_static_pad_template(ec, &sink_video);
    video_src = c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, caps);
    c.gst_element_class_add_pad_template(ec, video_src);
    c.gst_caps_unref(caps);
}

fn textBase(k: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const caps = c.gst_caps_new_simple("text/x-raw", "format", c.G_TYPE_STRING, "utf8", @as(?*anyopaque, null));
    c.gst_element_class_set_static_metadata(ec, "OGM text stream parser", "Codec/Decoder/Subtitle", "parse an OGM text header and stream", "GStreamer maintainers <gstreamer-devel@lists.freedesktop.org>");
    c.gst_element_class_add_static_pad_template(ec, &sink_text);
    text_src = c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_SOMETIMES, caps);
    c.gst_element_class_add_pad_template(ec, text_src);
    c.gst_caps_unref(caps);
}

fn audioInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    subInit(ogmOf(inst), &sink_audio, audio_src);
}

fn videoInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    subInit(ogmOf(inst), &sink_video, video_src);
}

fn textInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    subInit(ogmOf(inst), &sink_text, text_src);
}

fn subType(name: [*:0]const u8, base: c.GBaseInitFunc, init: c.GInstanceInitFunc) c.GType {
    const info = c.GTypeInfo{
        .class_size = @sizeOf(ElementClass),
        .base_init = base,
        .base_finalize = null,
        .class_init = null,
        .class_finalize = null,
        .class_data = null,
        .instance_size = @sizeOf(Ogm),
        .n_preallocs = 0,
        .instance_init = init,
        .value_table = null,
    };
    return c.g_type_register_static(ogmType(), name, &info, 0);
}

var riff_once: usize = 0;

fn ogmElementInit() void {
    if (c.g_once_init_enter(&riff_once) != 0) {
        c.gst_riff_init();
        _ = c._gst_debug_category_new("ogmparse", 0, "ogm parser");
        c.g_once_init_leave(&riff_once, 1);
    }
}

pub fn registerOgm(p: ?*c.GstPlugin) bool {
    var ok = false;
    ogmElementInit();
    ok = c.gst_element_register(p, "ogmaudioparse", c.GST_RANK_PRIMARY, audio_once.get(struct {
        fn f() c.GType {
            return subType("GstOgmAudioParse", audioBase, audioInit);
        }
    }.f)) != 0 or ok;
    ogmElementInit();
    ok = c.gst_element_register(p, "ogmvideoparse", c.GST_RANK_PRIMARY, video_once.get(struct {
        fn f() c.GType {
            return subType("GstOgmVideoParse", videoBase, videoInit);
        }
    }.f)) != 0 or ok;
    ogmElementInit();
    ok = c.gst_element_register(p, "ogmtextparse", c.GST_RANK_PRIMARY, text_once.get(struct {
        fn f() c.GType {
            return subType("GstOgmTextParse", textBase, textInit);
        }
    }.f)) != 0 or ok;
    return ok;
}

const Avi = extern struct {
    element: c.GstElement,
    sinkpad: ?*c.GstPad,
    srcpad: ?*c.GstPad,
    discont: c.gboolean,
    serial: c.gint,
    sync: c.ogg_sync_state,
    stream: c.ogg_stream_state,
};

var avi_src = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "audio/x-vorbis");
var avi_sink = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "application/x-ogg-avi");
var avi_once: cm.Once = .{};
var avi_parent: ?*c.GstElementClass = null;

fn aviOf(p: anytype) *Avi {
    return @ptrCast(@alignCast(p));
}

fn aviFinalize(ob: [*c]c.GObject) callconv(.c) void {
    const o = aviOf(ob);
    _ = c.ogg_sync_clear(&o.sync);
    _ = c.ogg_stream_clear(&o.stream);
    @as(*c.GObjectClass, @ptrCast(avi_parent.?)).finalize.?(ob);
}

fn aviSetCaps(pad: ?*c.GstPad, caps: [*c]c.GstCaps) bool {
    const o = aviOf(cm.obj(pad).parent);
    const st = c.gst_caps_get_structure(caps, 0);
    const cd = c.gst_structure_get_value(st, "codec_data");
    if (cd == null) return false;
    if (cd.*.g_type != c.gst_buffer_get_type()) return false;
    const b = c.gst_value_get_buffer(cd);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    const ptr = map.data + 22;
    var left = map.size -% 22;
    if (left < 12) return false;
    var sizes: [3]u32 = undefined;
    for (0..3) |i| sizes[i] = std.mem.readInt(u32, ptr[i * 4 ..][0..4], .little);
    left -= 12;
    if (left < @as(u64, sizes[0]) + sizes[1] + sizes[2]) return false;
    const oc = c.gst_caps_new_empty_simple("audio/x-vorbis");
    _ = cm.setCaps(o.srcpad, oc);
    c.gst_caps_unref(oc);
    var offs: usize = 34;
    for (sizes) |s| {
        _ = c.gst_pad_push(o.srcpad, c.gst_buffer_copy_region(b, c.GST_BUFFER_COPY_ALL, offs, s));
        offs += s;
    }
    return true;
}

fn aviEvent(pad: ?*c.GstPad, parent: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const o = aviOf(parent);
    switch (cm.eventType(ev)) {
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            const r = aviSetCaps(pad, caps);
            c.gst_event_unref(ev);
            return @intFromBool(r);
        },
        c.GST_EVENT_FLUSH_STOP => {
            _ = c.ogg_sync_reset(&o.sync);
            _ = c.ogg_stream_reset(&o.stream);
            o.discont = 1;
            return c.gst_pad_push_event(o.srcpad, ev);
        },
        else => return c.gst_pad_push_event(o.srcpad, ev),
    }
}

fn aviPush(o: *Avi, pk: *os.Packet) c.GstFlowReturn {
    const b = c.gst_buffer_new_allocate(null, @intCast(pk.bytes), null);
    _ = c.gst_buffer_fill(b, 0, pk.packet, @intCast(pk.bytes));
    cm.buf(b).offset_end = @bitCast(pk.granulepos);
    if (o.discont != 0) {
        cm.buf(b).mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        o.discont = 0;
    }
    return c.gst_pad_push(o.srcpad, b);
}

fn aviChain(_: ?*c.GstPad, parent: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const o = aviOf(parent);
    const size = c.gst_buffer_get_size(b);
    if (cm.buf(b).mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0) {
        _ = c.ogg_sync_reset(&o.sync);
        o.discont = 1;
    }
    const ob = c.ogg_sync_buffer(&o.sync, @intCast(size));
    _ = c.gst_buffer_extract(b, 0, ob, size);
    _ = c.ogg_sync_wrote(&o.sync, @intCast(size));
    c.gst_buffer_unref(b);
    while (true) {
        var page: c.ogg_page = undefined;
        const r = c.ogg_sync_pageout(&o.sync, &page);
        if (r == 0) break;
        if (r == -1) {
            o.discont = 1;
            continue;
        }
        if (o.serial == -1) {
            o.serial = c.ogg_page_serialno(&page);
            _ = c.ogg_stream_init(&o.stream, o.serial);
        }
        if (c.ogg_stream_pagein(&o.stream, &page) != 0) {
            _ = c.ogg_sync_reset(&o.sync);
            o.discont = 1;
            continue;
        }
        while (true) {
            var pk: os.Packet = undefined;
            const pr = c.ogg_stream_packetout(&o.stream, &pk);
            if (pr == 0) break;
            if (pr == -1) {
                o.discont = 1;
            } else if (pr == 1) {
                const res = aviPush(o, &pk);
                if (res != c.GST_FLOW_OK) return res;
            }
        }
    }
    return c.GST_FLOW_OK;
}

fn aviChange(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const o = aviOf(el);
    switch (t) {
        c.GST_STATE_CHANGE_NULL_TO_READY => _ = c.ogg_sync_init(&o.sync),
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            _ = c.ogg_sync_reset(&o.sync);
            _ = c.ogg_stream_reset(&o.stream);
            o.serial = -1;
            o.discont = 1;
        },
        else => {},
    }
    const r = avi_parent.?.change_state.?(el, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) _ = c.ogg_sync_clear(&o.sync);
    return r;
}

fn aviClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Ogg AVI parser", "Codec/Parser", "parse an ogg avi stream into pages (info about ogg: http://xiph.org)", "Wim Taymans <wim@fluendo.com>");
    c.gst_element_class_add_static_pad_template(ec, &avi_sink);
    c.gst_element_class_add_static_pad_template(ec, &avi_src);
    avi_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    ec.change_state = aviChange;
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.finalize = aviFinalize;
}

fn aviInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const o = aviOf(inst);
    o.sinkpad = c.gst_pad_new_from_static_template(&avi_sink, "sink");
    c.gst_pad_set_event_function_full(o.sinkpad, aviEvent, null, null);
    c.gst_pad_set_chain_function_full(o.sinkpad, aviChain, null, null);
    _ = c.gst_element_add_pad(&o.element, o.sinkpad);
    o.srcpad = c.gst_pad_new_from_static_template(&avi_src, "src");
    c.gst_pad_use_fixed_caps(o.srcpad);
    _ = c.gst_element_add_pad(&o.element, o.srcpad);
}

pub fn registerAvi(p: ?*c.GstPlugin) bool {
    const t = avi_once.get(struct {
        fn f() c.GType {
            const tt = cm.register(c.gst_element_get_type(), "GstOggAviParse", ElementClass, Avi, aviClassInit, aviInit);
            _ = c._gst_debug_category_new("oggaviparse", 0, "ogg avi parser");
            return tt;
        }
    }.f);
    return c.gst_element_register(p, "oggaviparse", c.GST_RANK_PRIMARY, t) != 0;
}
