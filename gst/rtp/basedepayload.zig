const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const buf = @import("buffer.zig");
const meta = @import("meta.zig");
const hdrext = @import("hdrext.zig");
const that = buf.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Depay = c.GstRTPBaseDepayload;
const Class = c.GstRTPBaseDepayloadClass;
const Ext = c.GstRTPHeaderExtension;
const PATH = "../gst-libs/gst/rtp/gstrtpbasedepayload.c";
const NONE = el.NONE;
const NO_SEQ: u32 = std.math.maxInt(u32);

const Private = struct {
    npt_start: c.GstClockTime,
    npt_stop: c.GstClockTime,
    play_speed: f64,
    play_scale: f64,
    clock_base: c.guint,
    onvif_mode: bool,
    discont: bool,
    pts: c.GstClockTime,
    dts: c.GstClockTime,
    duration: c.GstClockTime,
    ref_ts: c.GstClockTime,
    last_ssrc: u32,
    last_seqnum: u32,
    last_rtptime: u32,
    next_seqnum: u32,
    max_reorder: c.gint,
    auto_hdr_ext: bool,
    negotiated: bool,
    last_caps: [*c]c.GstCaps,
    segment_event: [*c]c.GstEvent,
    segment_seqnum: u32,
    source_info: bool,
    input: [*c]c.GstBuffer,
    flow: c.GstFlowReturn,
    exts: [*c]c.GPtrArray,
    aggregate: bool,
    seen: bool,
    pending: ?*c.GstBufferList,
    delayed: [*c]c.GstBuffer,
    outbuf: [*c]c.GstBuffer,
    read_result: bool,
};

const P = struct {
    const STATS = 1;
    const SOURCE_INFO = 2;
    const MAX_REORDER = 3;
    const AUTO_HEADER_EXTENSION = 4;
    const EXTENSIONS = 5;
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;
var cat: [*c]c.GstDebugCategory = null;
var ext_pspec: [*c]c.GParamSpec = null;
var sig_request: c.guint = 0;
var ntp_caps = c.GstStaticCaps{ .caps = null, .string = "timestamp/x-ntp", ._gst_reserved = .{null} ** 4 };

fn of(p: anytype) *Depay {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).priv));
}

fn klass(p: anytype) *Class {
    return el.classOf(Class, p);
}

fn exts(d: *Depay) []?*Ext {
    const a = priv(d).exts;
    if (a[0].len == 0) return &.{};
    return @as([*]?*Ext, @ptrCast(@alignCast(a[0].pdata)))[0..a[0].len];
}

fn notifyExtensions(d: *Depay) void {
    c.g_object_notify_by_pspec(@ptrCast(d), ext_pspec);
}

fn clearBuffer(slot: *[*c]c.GstBuffer) void {
    if (slot.* != null) c.gst_buffer_unref(slot.*);
    slot.* = null;
}

fn resetPending(d: *Depay) void {
    const r = priv(d);
    c.gst_mini_object_unref(@ptrCast(@alignCast(r.pending)));
    r.pending = c.gst_buffer_list_new();
}

pub export fn gst_rtp_base_depayload_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const info = c.GTypeInfo{
                .class_size = @sizeOf(Class),
                .base_init = null,
                .base_finalize = null,
                .class_init = classInit,
                .class_finalize = null,
                .class_data = null,
                .instance_size = @sizeOf(Depay),
                .n_preallocs = 0,
                .instance_init = @ptrCast(&init),
                .value_table = null,
            };
            const t = c.g_type_register_static(c.gst_element_get_type(), "GstRTPBaseDepayload", &info, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn requestDefault(d: *Depay, id: c.guint, uri: [*c]const u8) callconv(.c) [*c]Ext {
    if (!priv(d).auto_hdr_ext) return null;
    const e = hdrext.gst_rtp_header_extension_create_from_uri(uri);
    if (e != null) hdrext.gst_rtp_header_extension_set_id(e, id);
    return e;
}

const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    const dk: *Class = @ptrCast(@alignCast(k));
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    ok.finalize = finalize;
    ok.set_property = setProperty;
    ok.get_property = getProperty;
    const i = c.g_object_class_install_property;
    i(ok, P.STATS, c.g_param_spec_boxed("stats", "Statistics", "Various statistics", c.gst_structure_get_type(), RO));
    i(ok, P.SOURCE_INFO, c.g_param_spec_boolean("source-info", "RTP source information", "Add RTP source information as buffer meta", 0, RW));
    i(ok, P.MAX_REORDER, c.g_param_spec_int("max-reorder", "Max Reorder", "Max seqnum reorder before assuming sender has restarted", 0, std.math.maxInt(c.gint), 100, RW));
    i(ok, P.AUTO_HEADER_EXTENSION, c.g_param_spec_boolean("auto-header-extension", "Automatic RTP header extension", "Whether RTP header extensions should be automatically enabled, if an implementation is available", 1, RW));
    const t = c.G_TYPE_FROM_CLASS(k);
    sig_request = c.g_signal_new_class_handler("request-extension", t, c.G_SIGNAL_RUN_LAST, @ptrCast(&requestDefault), hdrext.accumulate, null, null, hdrext.gst_rtp_header_extension_get_type(), @as(c.guint, 2), c.G_TYPE_UINT, c.G_TYPE_STRING);
    _ = c.g_signal_new_class_handler("add-extension", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @ptrCast(&addExtension), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), hdrext.gst_rtp_header_extension_get_type());
    _ = c.g_signal_new_class_handler("clear-extensions", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @ptrCast(&clearExtensions), null, null, null, c.G_TYPE_NONE, @as(c.guint, 0));
    ext_pspec = c.gst_param_spec_array("extensions", "RTP header extensions", "A list of already enabled RTP header extensions", c.g_param_spec_object("extension", "RTP header extension", "An already enabled RTP extension", hdrext.gst_rtp_header_extension_get_type(), RO), RO);
    i(ok, P.EXTENSIONS, ext_pspec);
    ek.change_state = changeState;
    dk.packet_lost = packetLost;
    dk.handle_event = handleEvent;
    cat = c._gst_debug_category_new("rtpbasedepayload", 0, "Base class for RTP Depayloaders");
}

fn init(d: *Depay, k: *Class) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(k);
    d.priv = @ptrCast(@as([*]u8, @ptrCast(d)) + @as(usize, @bitCast(@as(isize, offset))));
    const r = priv(d);
    r.* = std.mem.zeroes(Private);
    var t = c.gst_element_class_get_pad_template(ek, "sink");
    if (!that(t != null, "gst_rtp_base_depayload_init", "pad_template != NULL")) return;
    d.sinkpad = c.gst_pad_new_from_template(t, "sink");
    c.gst_pad_set_chain_function_full(d.sinkpad, chain, null, null);
    c.gst_pad_set_chain_list_function_full(d.sinkpad, chainList, null, null);
    c.gst_pad_set_event_function_full(d.sinkpad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(d), d.sinkpad);
    t = c.gst_element_class_get_pad_template(ek, "src");
    if (!that(t != null, "gst_rtp_base_depayload_init", "pad_template != NULL")) return;
    d.srcpad = c.gst_pad_new_from_template(t, "src");
    c.gst_pad_use_fixed_caps(d.srcpad);
    _ = c.gst_element_add_pad(@ptrCast(d), d.srcpad);
    r.npt_start = 0;
    r.npt_stop = NONE;
    r.play_speed = 1.0;
    r.play_scale = 1.0;
    r.clock_base = std.math.maxInt(c.guint);
    r.dts = NONE;
    r.pts = NONE;
    r.duration = NONE;
    r.ref_ts = NONE;
    r.max_reorder = 100;
    r.auto_hdr_ext = true;
    c.gst_segment_init(&d.segment, c.GST_FORMAT_UNDEFINED);
    r.exts = c.g_ptr_array_new_with_free_func(c.gst_object_unref);
    r.pending = c.gst_buffer_list_new();
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const r = priv(o);
    c.g_ptr_array_unref(r.exts);
    if (r.pending != null) c.gst_mini_object_unref(@ptrCast(@alignCast(r.pending)));
    r.pending = null;
    clearBuffer(&r.delayed);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn fieldOf(s: ?*const c.GstStructure, name: [*:0]const u8, t: c.GType) ?[*c]const c.GValue {
    const v = c.gst_structure_get_value(s, name);
    if (v == null or c.g_type_check_value_holds(@constCast(v), t) == 0) return null;
    return v;
}

fn setCaps(d: *Depay, caps: [*c]c.GstCaps) bool {
    const r = priv(d);
    if (r.last_caps != null) {
        if (c.gst_caps_is_equal(r.last_caps, caps) != 0) return true;
        c.gst_caps_unref(r.last_caps);
        r.last_caps = null;
    }
    const s = c.gst_caps_get_structure(caps, 0);
    r.onvif_mode = if (fieldOf(s, "onvif-mode", c.G_TYPE_BOOLEAN)) |v| c.g_value_get_boolean(v) != 0 else false;
    if (r.onvif_mode) d.need_newsegment = 0;
    r.npt_start = if (fieldOf(s, "npt-start", c.G_TYPE_UINT64)) |v| c.g_value_get_uint64(v) else 0;
    r.npt_stop = if (fieldOf(s, "npt-stop", c.G_TYPE_UINT64)) |v| c.g_value_get_uint64(v) else NONE;
    r.play_speed = if (fieldOf(s, "play-speed", c.G_TYPE_DOUBLE)) |v| c.g_value_get_double(v) else 1.0;
    r.play_scale = if (fieldOf(s, "play-scale", c.G_TYPE_DOUBLE)) |v| c.g_value_get_double(v) else 1.0;
    r.clock_base = if (fieldOf(s, "clock-base", c.G_TYPE_UINT)) |v| c.g_value_get_uint(v) else std.math.maxInt(c.guint);
    if (!hdrext.syncFromCaps(d, r.exts, sig_request, caps)) return false;
    notifyExtensions(d);
    const ok = if (klass(d).set_caps) |set| set(d, caps) != 0 else true;
    r.negotiated = ok;
    if (ok) r.last_caps = @ptrCast(c.gst_mini_object_ref(@ptrCast(caps)));
    return ok;
}

fn elementError(d: *Depay, kind: c.GstMessageType, dom: el.Domain, code: c.gint, text: ?[*:0]const u8, debug: ?[*:0]const u8, comptime func: []const u8, line: c.gint) void {
    const t: [*c]u8 = if (text) |x| c.g_strdup(c.g_dgettext("gst-plugins-base-1.0", x)) else null;
    const g: [*c]u8 = if (debug) |x| c.g_strdup(x) else null;
    el.messageAt(d, kind, dom, code, t, g, PATH, func, line, null);
}

fn handleBuffer(d: *Depay, k: *Class, input: [*c]c.GstBuffer) c.GstFlowReturn {
    var in = input;
    const r = priv(d);
    r.flow = c.GST_FLOW_OK;
    if (!r.negotiated) {
        elementError(d, c.GST_MESSAGE_ERROR, .core, c.GST_CORE_ERROR_NEGOTIATION, "No RTP format was negotiated.", "Input buffers need to have RTP caps set on them. This is usually achieved by setting the 'caps' property of the upstream source element (often udpsrc or appsrc), or by putting a capsfilter element before the depayloader and setting the 'caps' property on that. Also see http://cgit.freedesktop.org/gstreamer/gst-plugins-good/tree/gst/rtp/README", "gst_rtp_base_depayload_handle_buffer", 956);
        c.gst_buffer_unref(in);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    const rc = c.gst_static_caps_get(&ntp_caps);
    const m = c.gst_buffer_get_reference_timestamp_meta(in, rc);
    c.gst_caps_unref(rc);
    if (m != null) {
        if (m[0].timestamp == r.ref_ts) {
            in = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(in)));
            _ = c.gst_buffer_remove_meta(in, @ptrCast(m));
        } else r.ref_ts = m[0].timestamp;
    }
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    if (buf.gst_rtp_buffer_map(in, c.GST_MAP_READ, &rtp) == 0) return invalid(d, in);
    const buf_discont = in[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0;
    r.pts = in[0].pts;
    r.dts = in[0].dts;
    r.duration = in[0].duration;
    const ssrc = buf.gst_rtp_buffer_get_ssrc(&rtp);
    const seq = buf.gst_rtp_buffer_get_seq(&rtp);
    const rtptime = buf.gst_rtp_buffer_get_timestamp(&rtp);
    r.last_seqnum = seq;
    r.last_rtptime = rtptime;
    var discont = buf_discont;
    if (r.next_seqnum != NO_SEQ) {
        if (ssrc != r.last_ssrc) {
            discont = true;
        } else {
            const gap = buf.gst_rtp_buffer_compare_seqnum(seq, @truncate(r.next_seqnum));
            if (gap != 0) {
                if (gap > 0 and gap <= r.max_reorder) {
                    buf.gst_rtp_buffer_unmap(&rtp);
                    c.gst_buffer_unref(in);
                    return c.GST_FLOW_OK;
                }
                discont = true;
            }
        }
    }
    r.next_seqnum = (@as(u32, seq) + 1) & 0xffff;
    r.last_ssrc = ssrc;
    if (discont) {
        r.discont = true;
        if (!buf_discont) {
            const old = in;
            in = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(in)));
            in[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
            if (in != old) {
                buf.gst_rtp_buffer_unmap(&rtp);
                if (buf.gst_rtp_buffer_map(in, c.GST_MAP_READ, &rtp) == 0) return invalid(d, in);
            }
        }
    }
    if (d.need_newsegment != 0) {
        r.segment_event = segmentEvent(d, rtptime, in[0].pts);
        d.need_newsegment = 0;
    }
    r.input = in;
    if (discont) resetPending(d);
    if (r.aggregate and !r.seen and buf.gst_rtp_buffer_get_extension(&rtp) != 0) r.seen = r.aggregate;
    if (r.seen) {
        const b = c.gst_buffer_new();
        _ = c.gst_buffer_copy_into(b, in, c.GST_BUFFER_COPY_MEMORY | c.GST_BUFFER_COPY_DEEP, 0, buf.gst_rtp_buffer_get_header_len(&rtp));
        c.gst_buffer_list_insert(r.pending, -1, b);
    }
    var out: [*c]c.GstBuffer = null;
    if (k.process_rtp_packet) |f| {
        out = f(d, &rtp);
        buf.gst_rtp_buffer_unmap(&rtp);
    } else if (k.process) |f| {
        buf.gst_rtp_buffer_unmap(&rtp);
        out = f(d, in);
    } else {
        buf.gst_rtp_buffer_unmap(&rtp);
        elementError(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, null, "The subclass does not have a process or process_rtp_packet method", "gst_rtp_base_depayload_handle_buffer", 985);
        c.gst_buffer_unref(in);
        return c.GST_FLOW_ERROR;
    }
    if (out != null) {
        if (r.flow == c.GST_FLOW_OK) {
            r.flow = gst_rtp_base_depayload_push(d, out);
        } else {
            c.gst_buffer_unref(out);
            resetPending(d);
        }
    }
    if (r.delayed != null) {
        c.gst_buffer_list_insert(r.pending, -1, r.delayed);
        r.delayed = null;
    }
    c.gst_buffer_unref(in);
    r.input = null;
    return r.flow;
}

fn invalid(d: *Depay, in: [*c]c.GstBuffer) c.GstFlowReturn {
    elementError(d, c.GST_MESSAGE_WARNING, .stream, c.GST_STREAM_ERROR_DECODE, null, "Received invalid RTP payload, dropping", "gst_rtp_base_depayload_handle_buffer", 970);
    c.gst_buffer_unref(in);
    return c.GST_FLOW_OK;
}

fn chain(_: ?*c.GstPad, o: [*c]c.GstObject, in: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    return handleBuffer(of(o), klass(o), in);
}

fn chainList(_: ?*c.GstPad, o: [*c]c.GstObject, list: ?*c.GstBufferList) callconv(.c) c.GstFlowReturn {
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    const n = c.gst_buffer_list_length(list);
    var i: c.guint = 0;
    while (i < n) : (i += 1) {
        const b = c.gst_buffer_list_get(list, i);
        _ = c.gst_mini_object_ref(@ptrCast(b));
        ret = handleBuffer(of(o), klass(o), b);
        if (ret != c.GST_FLOW_OK) break;
    }
    c.gst_mini_object_unref(@ptrCast(@alignCast(list)));
    return ret;
}

fn handleEvent(dd: [*c]Depay, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = of(dd);
    const r = priv(d);
    var res: c.gboolean = 1;
    var forward = true;
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_STOP => {
            el.lock(d);
            c.gst_segment_init(&d.segment, c.GST_FORMAT_UNDEFINED);
            el.unlock(d);
            d.need_newsegment = @intFromBool(!r.onvif_mode);
            r.next_seqnum = NO_SEQ;
            r.ref_ts = NONE;
            _ = c.gst_mini_object_replace(@ptrCast(&r.segment_event), null);
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            res = @intFromBool(setCaps(d, caps));
            forward = false;
        },
        c.GST_EVENT_SEGMENT => {
            var seg: c.GstSegment = undefined;
            el.lock(d);
            c.gst_event_copy_segment(ev, &seg);
            if (seg.format != c.GST_FORMAT_TIME) res = 0;
            r.segment_seqnum = c.gst_event_get_seqnum(ev);
            d.segment = seg;
            el.unlock(d);
            if (!r.onvif_mode) forward = false;
        },
        c.GST_EVENT_CUSTOM_DOWNSTREAM => {
            if (c.gst_event_has_name(ev, "GstRTPPacketLost") != 0) {
                if (klass(d).packet_lost) |f| res = f(d, ev);
                forward = false;
            }
        },
        else => {},
    }
    if (forward) return c.gst_pad_push_event(d.srcpad, ev);
    c.gst_event_unref(ev);
    return res;
}

fn sinkEvent(_: ?*c.GstPad, o: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (klass(o).handle_event) |f| return f(of(o), ev);
    c.gst_event_unref(ev);
    return 0;
}

fn segmentEvent(d: *Depay, rtptime: u32, pos: c.GstClockTime) [*c]c.GstEvent {
    const r = priv(d);
    var start = d.segment.start;
    if (r.clock_base != std.math.maxInt(c.guint) and pos != NONE) {
        var ext: u64 = r.clock_base;
        _ = buf.gst_rtp_buffer_ext_timestamp(&ext, rtptime);
        const gap = c.gst_util_uint64_scale_int(ext -% r.clock_base, @intCast(d.clock_rate), c.GST_SECOND);
        if (pos > gap) start = pos - gap;
    }
    var stop = d.segment.stop;
    if (r.npt_stop != NONE) stop = start +% (r.npt_stop -% r.npt_start);
    const position = if (pos == NONE) start else pos;
    const running = c.gst_segment_to_running_time(&d.segment, c.GST_FORMAT_TIME, start);
    var seg: c.GstSegment = undefined;
    c.gst_segment_init(&seg, c.GST_FORMAT_TIME);
    seg.rate = r.play_speed;
    seg.applied_rate = r.play_scale;
    seg.start = start;
    seg.stop = stop;
    seg.time = r.npt_start;
    seg.position = position;
    seg.base = running;
    const ev = c.gst_event_new_segment(&seg);
    if (r.segment_seqnum != c.GST_SEQNUM_INVALID) c.gst_event_set_seqnum(ev, r.segment_seqnum);
    return ev;
}

fn dropSourceMeta(_: [*c]c.GstBuffer, m: [*c][*c]c.GstMeta, _: c.gpointer) callconv(.c) c.gboolean {
    if (m.*[0].info[0].api == meta.gst_rtp_source_meta_api_get_type()) m.* = null;
    return 1;
}

fn addSourceMeta(out: [*c]c.GstBuffer, src: [*c]c.GstBuffer) void {
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    if (buf.gst_rtp_buffer_map(src, c.GST_MAP_READ, &rtp) == 0) return;
    defer buf.gst_rtp_buffer_unmap(&rtp);
    var ssrc = buf.gst_rtp_buffer_get_ssrc(&rtp);
    _ = c.gst_buffer_foreach_meta(out, dropSourceMeta, null);
    const m = meta.gst_buffer_add_rtp_source_meta(out, &ssrc, null, 0);
    if (m == null) return;
    const n = buf.gst_rtp_buffer_get_csrc_count(&rtp);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const v = buf.gst_rtp_buffer_get_csrc(&rtp, i);
        _ = meta.gst_rtp_source_meta_append_csrc(m, &v, 1);
    }
}

fn addExtension(d: *Depay, e: [*c]Ext) callconv(.c) void {
    const f = "gst_rtp_base_depayload_add_extension";
    if (!that(gtype.instanceOf(e, hdrext.gst_rtp_header_extension_get_type()), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return;
    if (!that(hdrext.gst_rtp_header_extension_get_id(e) > 0, f, "gst_rtp_header_extension_get_id (ext) > 0")) return;
    el.lock(d);
    c.g_ptr_array_add(priv(d).exts, c.gst_object_ref(e));
    el.unlock(d);
    notifyExtensions(d);
}

fn clearExtensions(d: *Depay) callconv(.c) void {
    el.lock(d);
    c.g_ptr_array_set_size(priv(d).exts, 0);
    el.unlock(d);
    notifyExtensions(d);
}

fn getExtensions(d: *Depay, out: [*c]c.GValue) void {
    el.lock(d);
    defer el.unlock(d);
    for (exts(d)) |e| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, hdrext.gst_rtp_header_extension_get_type());
        c.g_value_set_object(&v, e);
        c.gst_value_array_append_and_take_value(out, &v);
    }
}

fn readExtensions(d: *Depay, input: [*c]c.GstBuffer, output: [*c]c.GstBuffer) bool {
    if (input == null) return false;
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    if (buf.gst_rtp_buffer_map(input, c.GST_MAP_READ, &rtp) == 0) return false;
    defer buf.gst_rtp_buffer_unmap(&rtp);
    var pattern: u16 = 0;
    var ptr: c.gpointer = null;
    var wl: c.guint = 0;
    if (buf.gst_rtp_buffer_get_extension_data(&rtp, &pattern, &ptr, &wl) == 0) return false;
    const data: [*c]const u8 = @ptrCast(ptr);
    const len = @as(usize, wl) * 4;
    var flags: c.GstRTPHeaderExtensionFlags = 0;
    var unit: usize = 0;
    if (pattern == 0xBEDE) {
        unit = 1;
        flags = c.GST_RTP_HEADER_EXTENSION_ONE_BYTE;
    } else if (pattern >> 4 == 0x100) {
        unit = 2;
        flags = c.GST_RTP_HEADER_EXTENSION_TWO_BYTE;
    } else return false;
    var update = false;
    var o: usize = 0;
    while (o + unit < len) {
        var id: u8 = 0;
        var n: u8 = 0;
        if (unit == 1) {
            id = data[o] >> 4;
            n = (data[o] & 0x0f) + 1;
            o += 1;
            if (id == 0) continue;
            if (id == 15) break;
        } else {
            id = data[o];
            o += 1;
            if (id == 0) continue;
            n = data[o];
            o += 1;
        }
        if (o + n > len) break;
        el.lock(d);
        const hit: ?*Ext = for (exts(d)) |e| {
            if (id == hdrext.gst_rtp_header_extension_get_id(@ptrCast(e))) break e;
        } else null;
        if (hit) |e| {
            if (hdrext.gst_rtp_header_extension_read(@ptrCast(e), flags, data + o, n, output) == 0) {
                el.unlock(d);
                return update;
            }
            if (hdrext.gst_rtp_header_extension_wants_update_non_rtp_src_caps(@ptrCast(e)) != 0) update = true;
        }
        el.unlock(d);
        o += n;
    }
    return update;
}

fn readPending(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const d = of(data);
    const r = priv(d);
    if (readExtensions(d, b.*, r.outbuf)) r.read_result = true;
    return 1;
}

fn setHeaders(d: *Depay, b: [*c]c.GstBuffer) bool {
    const r = priv(d);
    if (b[0].pts == NONE) b[0].pts = r.pts;
    if (b[0].dts == NONE) b[0].dts = r.dts;
    if (b[0].duration == NONE) b[0].duration = r.duration;
    if (r.discont) {
        b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        r.discont = false;
    }
    r.pts = NONE;
    r.dts = NONE;
    r.duration = NONE;
    if (r.input == null) return false;
    if (r.source_info) addSourceMeta(b, r.input);
    if (!r.aggregate) return readExtensions(d, r.input, b);
    r.read_result = false;
    r.outbuf = b;
    if (c.gst_buffer_list_length(r.pending) == 0 and r.delayed != null) {
        c.gst_buffer_list_insert(r.pending, -1, r.delayed);
        r.delayed = null;
    }
    _ = c.gst_buffer_list_foreach(r.pending, readPending, d);
    r.outbuf = null;
    return r.read_result;
}

fn finishPush(d: *Depay, list: bool, obj: c.gpointer) c.GstFlowReturn {
    const r = priv(d);
    if (r.segment_event != null) {
        _ = c.gst_pad_push_event(d.srcpad, r.segment_event);
        r.segment_event = null;
    }
    if (list) return c.gst_pad_push_list(d.srcpad, @ptrCast(obj));
    return c.gst_pad_push(d.srcpad, @ptrCast(@alignCast(obj)));
}

fn srcCapsFromExtensions(d: *Depay) bool {
    const src = c.gst_pad_get_current_caps(d.srcpad);
    if (src == null) return true;
    defer c.gst_caps_unref(src);
    const next = c.gst_caps_copy(src);
    defer c.gst_caps_unref(next);
    var ok = true;
    for (exts(d)) |e| {
        ok = hdrext.gst_rtp_header_extension_update_non_rtp_src_caps(@ptrCast(e), next) != 0;
        if (!ok) {
            const name = @as(*c.GstObject, @ptrCast(@alignCast(e))).name;
            const text = c.g_strdup_printf("RTP header extension (%s) could not update src caps", name);
            el.messageAt(d, c.GST_MESSAGE_ERROR, .stream, c.GST_STREAM_ERROR_DECODE, text, null, PATH, "gst_rtp_base_depayload_set_src_caps_from_hdrext", 1550, null);
            break;
        }
    }
    if (ok and c.gst_caps_is_equal(src, next) == 0) _ = el.padSetCaps(d.srcpad, next);
    return ok;
}

fn doPush(d: *Depay, list: bool, obj: c.gpointer) c.GstFlowReturn {
    var res: c.GstFlowReturn = c.GST_FLOW_OK;
    if (list) {
        const l: ?*c.GstBufferList = @ptrCast(obj);
        var first: c.guint = 0;
        var i: c.guint = 0;
        var failed = false;
        while (i < c.gst_buffer_list_length(l)) : (i += 1) {
            const b = c.gst_buffer_list_get_writable(l, i);
            if (!setHeaders(d, b)) continue;
            var j = first;
            while (j < i) : (j += 1) {
                res = finishPush(d, false, c.gst_mini_object_ref(@ptrCast(c.gst_buffer_list_get(l, j))));
                if (res != c.GST_FLOW_OK) {
                    failed = true;
                    break;
                }
            }
            if (failed) break;
            first = i;
            if (!srcCapsFromExtensions(d)) {
                res = c.GST_FLOW_ERROR;
                failed = true;
                break;
            }
        }
        if (!failed) {
            if (first == 0) {
                res = finishPush(d, true, l);
                resetPending(d);
                return res;
            }
            i = first;
            while (i < c.gst_buffer_list_length(l)) : (i += 1) {
                res = finishPush(d, false, c.gst_mini_object_ref(@ptrCast(c.gst_buffer_list_get(l, i))));
                if (res != c.GST_FLOW_OK) break;
            }
        }
        c.gst_mini_object_unref(@ptrCast(@alignCast(l)));
    } else {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(obj));
        if (setHeaders(d, b) and !srcCapsFromExtensions(d)) {
            c.gst_buffer_unref(b);
            res = c.GST_FLOW_ERROR;
        } else res = finishPush(d, false, b);
    }
    resetPending(d);
    return res;
}

pub export fn gst_rtp_base_depayload_push(d: [*c]Depay, out: [*c]c.GstBuffer) c.GstFlowReturn {
    const res = doPush(of(d), false, out);
    if (res != c.GST_FLOW_OK) priv(d).flow = res;
    return res;
}

pub export fn gst_rtp_base_depayload_push_list(d: [*c]Depay, list: ?*c.GstBufferList) c.GstFlowReturn {
    const res = doPush(of(d), true, list);
    if (res != c.GST_FLOW_OK) priv(d).flow = res;
    return res;
}

fn packetLost(dd: [*c]Depay, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const d = of(dd);
    const s = c.gst_event_get_structure(ev);
    var ts: c.GstClockTime = NONE;
    var dur: c.GstClockTime = NONE;
    if (c.gst_structure_get_clock_time(s, "timestamp", &ts) == 0 or c.gst_structure_get_clock_time(s, "duration", &dur) == 0) return 0;
    const seg = c.gst_pad_get_sticky_event(d.srcpad, c.GST_EVENT_SEGMENT, 0);
    if (seg == null) return 0;
    c.gst_event_unref(seg);
    var fec: c.gboolean = 0;
    if (c.gst_structure_get_boolean(s, "might-have-been-fec", &fec) == 0 or fec == 0) {
        const gap = c.gst_event_new_gap(ts, dur);
        c.gst_event_set_gap_flags(gap, c.GST_GAP_FLAG_MISSING_DATA);
        return c.gst_pad_push_event(d.srcpad, gap);
    }
    return 1;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const d = of(e);
    const r = priv(d);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        d.need_newsegment = 1;
        r.npt_start = 0;
        r.npt_stop = NONE;
        r.play_speed = 1.0;
        r.play_scale = 1.0;
        r.clock_base = std.math.maxInt(c.guint);
        r.ref_ts = NONE;
        r.onvif_mode = false;
        r.next_seqnum = NO_SEQ;
        r.negotiated = false;
        r.discont = false;
        r.segment_seqnum = c.GST_SEQNUM_INVALID;
        r.seen = false;
        clearBuffer(&r.delayed);
        resetPending(d);
    }
    const ret = parent.?.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        _ = c.gst_mini_object_replace(@ptrCast(&r.last_caps), null);
        _ = c.gst_mini_object_replace(@ptrCast(&r.segment_event), null);
    }
    return ret;
}

fn stats(d: *Depay) ?*c.GstStructure {
    const r = priv(d);
    var pts: c.GstClockTime = NONE;
    var dts: c.GstClockTime = NONE;
    el.lock(d);
    if (d.segment.format != c.GST_FORMAT_UNDEFINED) {
        pts = c.gst_segment_to_running_time(&d.segment, c.GST_FORMAT_TIME, r.pts);
        dts = c.gst_segment_to_running_time(&d.segment, c.GST_FORMAT_TIME, r.dts);
    }
    el.unlock(d);
    return c.gst_structure_new("application/x-rtp-depayload-stats", "clock_rate", c.G_TYPE_UINT, d.clock_rate, "npt-start", c.G_TYPE_UINT64, r.npt_start, "npt-stop", c.G_TYPE_UINT64, r.npt_stop, "play-speed", c.G_TYPE_DOUBLE, r.play_speed, "play-scale", c.G_TYPE_DOUBLE, r.play_scale, "running-time-dts", c.G_TYPE_UINT64, dts, "running-time-pts", c.G_TYPE_UINT64, pts, "seqnum", c.G_TYPE_UINT, r.last_seqnum, "timestamp", c.G_TYPE_UINT, r.last_rtptime, @as(?*anyopaque, null));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const r = priv(o);
    switch (id) {
        P.SOURCE_INFO => gst_rtp_base_depayload_set_source_info_enabled(of(o), c.g_value_get_boolean(v)),
        P.MAX_REORDER => r.max_reorder = c.g_value_get_int(v),
        P.AUTO_HEADER_EXTENSION => r.auto_hdr_ext = c.g_value_get_boolean(v) != 0,
        else => el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 1843),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const d = of(o);
    const r = priv(o);
    switch (id) {
        P.STATS => c.g_value_take_boxed(v, stats(d)),
        P.SOURCE_INFO => c.g_value_set_boolean(v, @intFromBool(r.source_info)),
        P.MAX_REORDER => c.g_value_set_int(v, r.max_reorder),
        P.AUTO_HEADER_EXTENSION => c.g_value_set_boolean(v, @intFromBool(r.auto_hdr_ext)),
        P.EXTENSIONS => getExtensions(d, v),
        else => el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 1877),
    }
}

pub export fn gst_rtp_base_depayload_set_source_info_enabled(d: [*c]Depay, enable: c.gboolean) void {
    priv(d).source_info = enable != 0;
}

pub export fn gst_rtp_base_depayload_is_source_info_enabled(d: [*c]Depay) c.gboolean {
    return @intFromBool(priv(d).source_info);
}

pub export fn gst_rtp_base_depayload_set_aggregate_hdrext_enabled(d: [*c]Depay, enable: c.gboolean) void {
    priv(d).aggregate = enable != 0;
    if (enable == 0) resetPending(of(d));
}

pub export fn gst_rtp_base_depayload_is_aggregate_hdrext_enabled(d: [*c]Depay) c.gboolean {
    return @intFromBool(priv(d).aggregate);
}

pub export fn gst_rtp_base_depayload_dropped(d: [*c]Depay) void {
    const r = priv(d);
    const n = c.gst_buffer_list_length(r.pending);
    if (r.delayed != null) {
        clearBuffer(&r.delayed);
    } else if (n != 0) c.gst_buffer_list_remove(r.pending, n - 1, 1);
}

pub export fn gst_rtp_base_depayload_delayed(d: [*c]Depay) void {
    const r = priv(d);
    const n = c.gst_buffer_list_length(r.pending);
    if (n == 0) return;
    r.delayed = c.gst_buffer_list_get(r.pending, n - 1);
    _ = c.gst_mini_object_ref(@ptrCast(r.delayed));
    c.gst_buffer_list_remove(r.pending, n - 1, 1);
}

pub export fn gst_rtp_base_depayload_flush(d: [*c]Depay, keep: c.gboolean) void {
    const r = priv(d);
    const n = c.gst_buffer_list_length(r.pending);
    if (keep == 0 or r.delayed != null) {
        resetPending(of(d));
    } else if (n != 0) {
        const b = c.gst_buffer_list_get(r.pending, n - 1);
        _ = c.gst_mini_object_ref(@ptrCast(b));
        resetPending(of(d));
        c.gst_buffer_list_insert(r.pending, -1, b);
    }
}
