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

const Pay = c.GstRTPBasePayload;
const Class = c.GstRTPBasePayloadClass;
const Ext = c.GstRTPHeaderExtension;
const PATH = "../gst-libs/gst/rtp/gstrtpbasepayload.c";
const NONE = el.NONE;

const DEFAULT_MTU = 1400;
const DEFAULT_PT = 96;
const ONE_BYTE_MAX_SIZE = 16;
const TWO_BYTE_MAX_SIZE = 255;
const ONE_BYTE_MAX_ID = 14;
const TWO_BYTE_MAX_ID = 255;

const Private = struct {
    ts_offset_random: bool,
    seqnum_offset_random: bool,
    ssrc_random: bool,
    next_seqnum: u16,
    perfect_rtptime: bool,
    notified_first_timestamp: c.gint,
    pt_set: bool,
    source_info: bool,
    input_meta: [*c]c.GstBuffer,
    base_offset: u64,
    base_rtime: i64,
    base_rtime_hz: u64,
    running_time: u64,
    scale_rtptime: bool,
    auto_hdr_ext: bool,
    prop_max_ptime: i64,
    caps_max_ptime: i64,
    onvif_no_rate_control: bool,
    negotiated: bool,
    negotiate_called: bool,
    delay_segment: bool,
    pending_segment: [*c]c.GstEvent,
    subclass_srccaps: [*c]c.GstCaps,
    sinkcaps: [*c]c.GstCaps,
    exts: [*c]c.GPtrArray,
};

const P = struct {
    const MTU = 1;
    const PT = 2;
    const SSRC = 3;
    const TIMESTAMP_OFFSET = 4;
    const SEQNUM_OFFSET = 5;
    const MAX_PTIME = 6;
    const MIN_PTIME = 7;
    const TIMESTAMP = 8;
    const SEQNUM = 9;
    const PERFECT_RTPTIME = 10;
    const PTIME_MULTIPLE = 11;
    const STATS = 12;
    const SOURCE_INFO = 13;
    const ONVIF_NO_RATE_CONTROL = 14;
    const SCALE_RTPTIME = 15;
    const AUTO_HEADER_EXTENSION = 16;
    const EXTENSIONS = 17;
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*c.GstElementClass = null;
var cat: [*c]c.GstDebugCategory = null;
var ext_pspec: [*c]c.GParamSpec = null;
var sig_request: c.guint = 0;

fn of(p: anytype) *Pay {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).priv));
}

fn klass(p: anytype) *Class {
    return el.classOf(Class, p);
}

fn notifyExtensions(p: *Pay) void {
    c.g_object_notify_by_pspec(@ptrCast(p), ext_pspec);
}

fn replaceCaps(slot: *[*c]c.GstCaps, caps: [*c]c.GstCaps) void {
    _ = c.gst_mini_object_replace(@ptrCast(slot), @ptrCast(caps));
}

fn replaceEvent(slot: *[*c]c.GstEvent, ev: [*c]c.GstEvent) void {
    _ = c.gst_mini_object_replace(@ptrCast(slot), @ptrCast(ev));
}

pub export fn gst_rtp_base_payload_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const info = c.GTypeInfo{
                .class_size = @sizeOf(Class),
                .base_init = null,
                .base_finalize = null,
                .class_init = classInit,
                .class_finalize = null,
                .class_data = null,
                .instance_size = @sizeOf(Pay),
                .n_preallocs = 0,
                .instance_init = @ptrCast(&init),
                .value_table = null,
            };
            const t = c.g_type_register_static(c.gst_element_get_type(), "GstRTPBasePayload", &info, c.G_TYPE_FLAG_ABSTRACT);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn requestDefault(p: *Pay, id: c.guint, uri: [*c]const u8) callconv(.c) [*c]Ext {
    if (!priv(p).auto_hdr_ext) return null;
    const e = hdrext.gst_rtp_header_extension_create_from_uri(uri);
    if (e != null) hdrext.gst_rtp_header_extension_set_id(e, id);
    return e;
}

const RW = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS;
const RO = c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS;

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    const pk: *Class = @ptrCast(@alignCast(k));
    if (offset != 0) c.g_type_class_adjust_private_offset(k, &offset);
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    ok.finalize = finalize;
    ok.set_property = setProperty;
    ok.get_property = getProperty;
    const i = c.g_object_class_install_property;
    i(ok, P.MTU, c.g_param_spec_uint("mtu", "MTU", "Maximum size of one packet", 28, std.math.maxInt(c.guint), DEFAULT_MTU, RW));
    i(ok, P.PT, c.g_param_spec_uint("pt", "payload type", "The payload type of the packets", 0, 0x7f, DEFAULT_PT, RW));
    i(ok, P.SSRC, c.g_param_spec_uint("ssrc", "SSRC", "The SSRC of the packets (default == random)", 0, std.math.maxInt(u32), std.math.maxInt(u32), RW));
    i(ok, P.TIMESTAMP_OFFSET, c.g_param_spec_uint("timestamp-offset", "Timestamp Offset", "Offset to add to all outgoing timestamps (default = random)", 0, std.math.maxInt(u32), std.math.maxInt(u32), RW));
    i(ok, P.SEQNUM_OFFSET, c.g_param_spec_int("seqnum-offset", "Sequence number Offset", "Offset to add to all outgoing seqnum (-1 = random)", -1, std.math.maxInt(u16), -1, RW));
    i(ok, P.MAX_PTIME, c.g_param_spec_int64("max-ptime", "Max packet time", "Maximum duration of the packet data in ns (-1 = unlimited up to MTU)", -1, std.math.maxInt(i64), -1, RW));
    i(ok, P.MIN_PTIME, c.g_param_spec_int64("min-ptime", "Min packet time", "Minimum duration of the packet data in ns (can't go above MTU)", 0, std.math.maxInt(i64), 0, RW));
    i(ok, P.TIMESTAMP, c.g_param_spec_uint("timestamp", "Timestamp", "The RTP timestamp of the last processed packet", 0, std.math.maxInt(u32), 0, RO));
    i(ok, P.SEQNUM, c.g_param_spec_uint("seqnum", "Sequence number", "The RTP sequence number of the last processed packet", 0, std.math.maxInt(u16), 0, RO));
    i(ok, P.PERFECT_RTPTIME, c.g_param_spec_boolean("perfect-rtptime", "Perfect RTP Time", "Generate perfect RTP timestamps when possible", 1, RW));
    i(ok, P.PTIME_MULTIPLE, c.g_param_spec_int64("ptime-multiple", "Packet time multiple", "Force buffers to be multiples of this duration in ns (0 disables)", 0, std.math.maxInt(i64), 0, RW));
    i(ok, P.STATS, c.g_param_spec_boxed("stats", "Statistics", "Various statistics", c.gst_structure_get_type(), RO));
    i(ok, P.SOURCE_INFO, c.g_param_spec_boolean("source-info", "RTP source information", "Write CSRC based on buffer meta RTP source information", 0, c.G_PARAM_READWRITE));
    i(ok, P.ONVIF_NO_RATE_CONTROL, c.g_param_spec_boolean("onvif-no-rate-control", "ONVIF no rate control", "Enable ONVIF Rate-Control=no timestamping mode", 0, RW));
    i(ok, P.SCALE_RTPTIME, c.g_param_spec_boolean("scale-rtptime", "Scale RTP time", "Whether the RTP timestamp should be scaled with the rate (speed)", 1, RW));
    i(ok, P.AUTO_HEADER_EXTENSION, c.g_param_spec_boolean("auto-header-extension", "Automatic RTP header extension", "Whether RTP header extensions should be automatically enabled, if an implementation is available", 1, RW));
    ext_pspec = c.gst_param_spec_array("extensions", "RTP header extensions", "A list of already enabled RTP header extensions", c.g_param_spec_object("extension", "RTP header extension", "An already enabled RTP extension", hdrext.gst_rtp_header_extension_get_type(), RO), RO);
    i(ok, P.EXTENSIONS, ext_pspec);
    const t = c.G_TYPE_FROM_CLASS(k);
    _ = c.g_signal_new_class_handler("add-extension", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @ptrCast(&addExtension), null, null, null, c.G_TYPE_NONE, @as(c.guint, 1), hdrext.gst_rtp_header_extension_get_type());
    sig_request = c.g_signal_new_class_handler("request-extension", t, c.G_SIGNAL_RUN_LAST, @ptrCast(&requestDefault), hdrext.accumulate, null, null, hdrext.gst_rtp_header_extension_get_type(), @as(c.guint, 2), c.G_TYPE_UINT, c.G_TYPE_STRING);
    _ = c.g_signal_new_class_handler("clear-extensions", t, c.G_SIGNAL_RUN_LAST | c.G_SIGNAL_ACTION, @ptrCast(&clearExtensions), null, null, null, c.G_TYPE_NONE, @as(c.guint, 0));
    ek.change_state = changeState;
    pk.get_caps = getCapsDefault;
    pk.sink_event = sinkEventDefault;
    pk.src_event = srcEventDefault;
    pk.query = queryDefault;
    cat = c._gst_debug_category_new("rtpbasepayload", 0, "Base class for RTP Payloaders");
}

fn init(p: *Pay, k: *Class) callconv(.c) void {
    const ek: *c.GstElementClass = @ptrCast(k);
    p.priv = @ptrCast(@as([*]u8, @ptrCast(p)) + @as(usize, @bitCast(@as(isize, offset))));
    const r = priv(p);
    r.* = std.mem.zeroes(Private);
    var t = c.gst_element_class_get_pad_template(ek, "src");
    if (!that(t != null, "gst_rtp_base_payload_init", "templ != NULL")) return;
    p.srcpad = c.gst_pad_new_from_template(t, "src");
    c.gst_pad_set_event_function_full(p.srcpad, srcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(p), p.srcpad);
    t = c.gst_element_class_get_pad_template(ek, "sink");
    if (!that(t != null, "gst_rtp_base_payload_init", "templ != NULL")) return;
    p.sinkpad = c.gst_pad_new_from_template(t, "sink");
    c.gst_pad_set_chain_function_full(p.sinkpad, chain, null, null);
    c.gst_pad_set_event_function_full(p.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(p.sinkpad, query, null, null);
    _ = c.gst_element_add_pad(@ptrCast(p), p.sinkpad);
    p.mtu = DEFAULT_MTU;
    p.pt = DEFAULT_PT;
    p.seqnum_offset = -1;
    p.ssrc = std.math.maxInt(c.guint);
    p.ts_offset = -1;
    r.running_time = NONE;
    r.seqnum_offset_random = true;
    r.ts_offset_random = true;
    r.ssrc_random = true;
    p.max_ptime = -1;
    p.min_ptime = 0;
    r.perfect_rtptime = true;
    p.ptime_multiple = 0;
    r.base_offset = NONE;
    r.base_rtime_hz = NONE;
    r.scale_rtptime = true;
    r.auto_hdr_ext = true;
    p.media = null;
    p.encoding_name = null;
    p.clock_rate = 0;
    r.caps_max_ptime = -1;
    r.prop_max_ptime = -1;
    r.exts = c.g_ptr_array_new_with_free_func(c.gst_object_unref);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const p = of(o);
    c.g_free(p.media);
    p.media = null;
    c.g_free(p.encoding_name);
    p.encoding_name = null;
    replaceCaps(&priv(p).subclass_srccaps, null);
    replaceCaps(&priv(p).sinkcaps, null);
    c.g_ptr_array_unref(priv(p).exts);
    priv(p).exts = null;
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn getCapsDefault(_: [*c]Pay, pad: ?*c.GstPad, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const tmpl = c.gst_pad_get_pad_template(pad);
    defer c.gst_object_unref(tmpl);
    const caps = tmpl[0].caps;
    if (filter != null) return c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    return @ptrCast(c.gst_mini_object_ref(@ptrCast(caps)));
}

fn sinkEventDefault(pp: [*c]Pay, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = of(pp);
    const r = priv(p);
    const obj: *c.GstObject = @ptrCast(p);
    switch (ev[0].type) {
        c.GST_EVENT_FLUSH_STOP => {
            const res = c.gst_pad_event_default(p.sinkpad, obj, ev);
            c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
            replaceEvent(&r.pending_segment, null);
            return res;
        },
        c.GST_EVENT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_event_parse_caps(ev, &caps);
            replaceCaps(&r.sinkcaps, caps);
            const res: c.gboolean = if (klass(p).set_caps) |set| set(p, caps) else @intFromBool(negotiate(p));
            r.negotiated = res != 0;
            c.gst_event_unref(ev);
            return res;
        },
        c.GST_EVENT_SEGMENT => {
            c.gst_event_copy_segment(ev, &p.segment);
            r.base_offset = NONE;
            if (r.delay_segment) {
                replaceEvent(&r.pending_segment, ev);
                c.gst_event_unref(ev);
                return 1;
            }
            return c.gst_pad_event_default(p.sinkpad, obj, ev);
        },
        c.GST_EVENT_GAP => {
            flushPendingSegment(p);
            return c.gst_pad_event_default(p.sinkpad, obj, ev);
        },
        else => return c.gst_pad_event_default(p.sinkpad, obj, ev),
    }
}

fn flushPendingSegment(p: *Pay) void {
    const r = priv(p);
    if (r.pending_segment == null) return;
    _ = c.gst_pad_push_event(p.srcpad, r.pending_segment);
    r.pending_segment = null;
    r.delay_segment = false;
}

fn sinkEvent(_: ?*c.GstPad, o: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = of(o);
    if (klass(p).sink_event) |f| return f(p, ev);
    c.gst_event_unref(ev);
    return 0;
}

fn srcEventDefault(pp: [*c]Pay, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = of(pp);
    var res: c.gboolean = 1;
    var forward = true;
    if (ev[0].type == c.GST_EVENT_CUSTOM_UPSTREAM) {
        const s = c.gst_event_get_structure(ev);
        if (c.gst_structure_has_name(s, "GstRTPCollision") != 0) {
            var ssrc: c.guint = 0;
            if (c.gst_structure_get_uint(s, "ssrc", &ssrc) == 0) ssrc = std.math.maxInt(c.guint);
            if (ssrc == p.current_ssrc) {
                var suggested: c.guint = 0;
                if (c.gst_structure_get_uint(s, "suggested-ssrc", &suggested) != 0) p.current_ssrc = suggested;
                while (ssrc == p.current_ssrc) p.current_ssrc = c.g_random_int();
                var caps = c.gst_pad_get_current_caps(p.srcpad);
                if (caps != null) {
                    caps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
                    c.gst_caps_set_simple(caps, "ssrc", c.G_TYPE_UINT, p.current_ssrc, @as(?*anyopaque, null));
                    res = @intFromBool(el.padSetCaps(p.srcpad, caps));
                    c.gst_caps_unref(caps);
                }
                forward = false;
            }
        }
    }
    if (forward) return c.gst_pad_event_default(p.srcpad, @ptrCast(p), ev);
    c.gst_event_unref(ev);
    return res;
}

fn srcEvent(_: ?*c.GstPad, o: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = of(o);
    if (klass(p).src_event) |f| return f(p, ev);
    c.gst_event_unref(ev);
    return 0;
}

fn queryDefault(pp: [*c]Pay, pad: ?*c.GstPad, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const p = of(pp);
    if (q[0].type != c.GST_QUERY_CAPS) return c.gst_pad_query_default(pad, @ptrCast(p), q);
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    const get = klass(p).get_caps orelse return 0;
    const caps = get(p, pad, filter);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn query(pad: ?*c.GstPad, o: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const p = of(o);
    return if (klass(p).query) |f| f(p, pad, q) else 0;
}

fn elementError(p: *Pay, d: el.Domain, code: c.gint, debug: [*:0]const u8, comptime func: []const u8, line: c.gint) void {
    el.errAt(p, d, code, null, c.g_strdup(debug), "gst-plugins-base-1.0", PATH, func, line);
}

fn chain(_: ?*c.GstPad, o: [*c]c.GstObject, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const p = of(o);
    const r = priv(p);
    const handle = klass(p).handle_buffer orelse {
        elementError(p, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, "subclass did not implement handle_buffer function", "gst_rtp_base_payload_chain", 912);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    };
    if (!r.negotiated) {
        elementError(p, .core, c.GST_CORE_ERROR_NEGOTIATION, "No input format was negotiated, i.e. no caps event was received. Perhaps you need a parser or typefind element before the payloader", "gst_rtp_base_payload_chain", 919);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (r.source_info or r.exts[0].len > 0 or !r.negotiate_called) {
        r.input_meta = c.gst_buffer_new();
        _ = c.gst_buffer_copy_into(r.input_meta, b, c.GST_BUFFER_COPY_METADATA, 0, std.math.maxInt(usize));
    }
    if (c.gst_pad_check_reconfigure(p.srcpad) != 0 and !negotiate(p)) {
        c.gst_pad_mark_reconfigure(p.srcpad);
        const flushing = el.flags(p.srcpad) & c.GST_PAD_FLAG_FLUSHING != 0;
        c.gst_buffer_unref(b);
        return if (flushing) c.GST_FLOW_FLUSHING else c.GST_FLOW_NOT_NEGOTIATED;
    }
    const ret = handle(p, b);
    _ = c.gst_mini_object_replace(@ptrCast(&r.input_meta), null);
    return ret;
}

pub export fn gst_rtp_base_payload_set_options(p: [*c]Pay, media: [*c]const u8, dynamic: c.gboolean, encoding: [*c]const u8, rate: c.guint32) void {
    const f = "gst_rtp_base_payload_set_options";
    if (!that(p != null, f, "payload != NULL")) return;
    if (!that(rate != 0, f, "clock_rate != 0")) return;
    c.g_free(p[0].media);
    p[0].media = c.g_strdup(media);
    p[0].dynamic = dynamic;
    c.g_free(p[0].encoding_name);
    p[0].encoding_name = c.g_strdup(encoding);
    p[0].clock_rate = rate;
}

fn copyFixed(field: ?*const c.GstIdStr, v: [*c]const c.GValue, dest: c.gpointer) callconv(.c) c.gboolean {
    if (c.gst_value_is_fixed(v) != 0) c.gst_structure_id_str_set_value(@ptrCast(@alignCast(dest)), field, v);
    return 1;
}

fn updateMaxPtime(p: *Pay) void {
    const r = priv(p);
    p.max_ptime = if (r.caps_max_ptime != -1 and r.prop_max_ptime != -1)
        @min(r.caps_max_ptime, r.prop_max_ptime)
    else if (r.caps_max_ptime != -1)
        r.caps_max_ptime
    else
        r.prop_max_ptime;
}

fn setCapsField(field: ?*const c.GstIdStr, v: [*c]const c.GValue, caps: c.gpointer) callconv(.c) c.gboolean {
    c.gst_caps_set_value(@ptrCast(@alignCast(caps)), c.gst_id_str_as_str(field), v);
    return 1;
}

pub export fn gst_rtp_base_payload_set_outcaps_structure(p: [*c]Pay, s: ?*c.GstStructure) c.gboolean {
    const caps = c.gst_caps_new_simple("application/x-rtp", "media", c.G_TYPE_STRING, p[0].media, "clock-rate", c.G_TYPE_INT, p[0].clock_rate, "encoding-name", c.G_TYPE_STRING, p[0].encoding_name, @as(?*anyopaque, null));
    if (s != null and c.gst_structure_n_fields(s) > 0) _ = c.gst_structure_foreach_id_str(s, setCapsField, caps);
    replaceCaps(&priv(p).subclass_srccaps, caps);
    c.gst_caps_unref(caps);
    return @intFromBool(negotiate(of(p)));
}

pub export fn gst_rtp_base_payload_set_outcaps(p: [*c]Pay, field: [*c]const u8, ...) callconv(.c) c.gboolean {
    var s: ?*c.GstStructure = null;
    if (field != null) {
        s = c.gst_structure_new_empty("unused");
        var ap = @cVaStart();
        c.gst_structure_set_valist(s, field, @ptrCast(&ap));
        @cVaEnd(&ap);
    }
    const res = gst_rtp_base_payload_set_outcaps_structure(p, s);
    if (s != null) c.gst_structure_free(s);
    return res;
}

fn exts(p: *Pay) []?*Ext {
    const a = priv(p).exts;
    if (a[0].len == 0) return &.{};
    const d: [*]?*Ext = @ptrCast(@alignCast(a[0].pdata));
    return d[0..a[0].len];
}

fn probe(templ: [*c]c.GstCaps, temp: *[*c]c.GstCaps, field: [*:0]const u8, gtype_: c.GType, v: anytype) bool {
    const pc = c.gst_caps_copy(templ);
    defer c.gst_caps_unref(pc);
    c.gst_caps_set_simple(pc, field, gtype_, v, @as(?*anyopaque, null));
    const x = c.gst_caps_intersect(pc, temp.*);
    if (c.gst_caps_is_empty(x) == 0) {
        c.gst_caps_unref(temp.*);
        temp.* = x;
        return true;
    }
    c.gst_caps_unref(x);
    return false;
}

fn negotiate(p: *Pay) bool {
    const r = priv(p);
    r.caps_max_ptime = -1;
    p.ptime = 0;
    _ = c.gst_pad_check_reconfigure(p.srcpad);
    var templ = c.gst_pad_get_pad_template_caps(p.srcpad);
    if (r.subclass_srccaps != null) {
        const x = c.gst_caps_intersect(r.subclass_srccaps, templ);
        c.gst_caps_unref(templ);
        templ = x;
    }
    var res = true;
    var srccaps: [*c]c.GstCaps = null;
    const peer = c.gst_pad_peer_query_caps(p.srcpad, templ);
    if (peer == null) {
        srccaps = c.gst_caps_copy(templ);
        c.gst_caps_set_simple(srccaps, "payload", c.G_TYPE_INT, p.pt, "ssrc", c.G_TYPE_UINT, p.current_ssrc, "timestamp-offset", c.G_TYPE_UINT, p.ts_base, "seqnum-offset", c.G_TYPE_UINT, @as(c.guint, p.seqnum_base), @as(?*anyopaque, null));
    } else {
        var temp: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(peer)));
        if (c.gst_caps_is_empty(temp) != 0) {
            c.gst_caps_unref(temp);
            c.gst_caps_unref(templ);
            r.negotiate_called = true;
            c.gst_pad_mark_reconfigure(p.srcpad);
            return false;
        }
        var have_pt = false;
        if (r.pt_set or c.gst_pad_has_current_caps(p.srcpad) != 0) have_pt = probe(templ, &temp, "payload", c.G_TYPE_INT, p.pt);
        if (!have_pt) {
            const s = c.gst_caps_get_structure(temp, 0);
            var pt: c.gint = 0;
            if (c.gst_structure_get_int(s, "payload", &pt) != 0) {
                p.pt = @bitCast(pt);
            } else if (c.gst_structure_has_field(s, "payload") != 0) {
                _ = c.gst_structure_fixate_field_nearest_int(s, "payload", @bitCast(p.pt));
                _ = c.gst_structure_get_int(s, "payload", &pt);
                p.pt = @bitCast(pt);
            } else {
                c.gst_structure_set(s, "payload", c.G_TYPE_INT, p.pt, @as(?*anyopaque, null));
            }
        }
        {
            const s = c.gst_caps_get_structure(temp, 0);
            if (c.gst_structure_has_field_typed(s, "ssrc", c.G_TYPE_UINT) != 0) {
                p.current_ssrc = c.g_value_get_uint(c.gst_structure_get_value(s, "ssrc"));
            } else c.gst_structure_set(s, "ssrc", c.G_TYPE_UINT, p.current_ssrc, @as(?*anyopaque, null));
        }
        var have_ts = false;
        if (!r.ts_offset_random or c.gst_pad_has_current_caps(p.srcpad) != 0) have_ts = probe(templ, &temp, "timestamp-offset", c.G_TYPE_UINT, p.ts_base);
        if (!have_ts) {
            const s = c.gst_caps_get_structure(temp, 0);
            if (c.gst_structure_has_field_typed(s, "timestamp-offset", c.G_TYPE_UINT) != 0) {
                p.ts_base = c.g_value_get_uint(c.gst_structure_get_value(s, "timestamp-offset"));
            } else c.gst_structure_set(s, "timestamp-offset", c.G_TYPE_UINT, p.ts_base, @as(?*anyopaque, null));
        }
        var have_seq = false;
        if (!r.seqnum_offset_random or c.gst_pad_has_current_caps(p.srcpad) != 0) have_seq = probe(templ, &temp, "seqnum-offset", c.G_TYPE_UINT, @as(c.guint, p.seqnum_base));
        if (!have_seq) {
            const s = c.gst_caps_get_structure(temp, 0);
            if (c.gst_structure_has_field_typed(s, "seqnum-offset", c.G_TYPE_UINT) != 0) {
                p.seqnum_base = @truncate(c.g_value_get_uint(c.gst_structure_get_value(s, "seqnum-offset")));
                r.next_seqnum = p.seqnum_base;
                p.seqnum = p.seqnum_base;
                r.seqnum_offset_random = false;
            } else c.gst_structure_set(s, "seqnum-offset", c.G_TYPE_UINT, @as(c.guint, p.seqnum_base), @as(?*anyopaque, null));
        }
        temp = c.gst_caps_truncate(temp);
        const s = c.gst_caps_get_structure(temp, 0);
        var ms: c.guint = 0;
        if (c.gst_structure_get_uint(s, "maxptime", &ms) != 0) r.caps_max_ptime = @intCast(@as(u64, ms) * c.GST_MSECOND);
        if (c.gst_structure_get_uint(s, "ptime", &ms) != 0) p.ptime = @as(u64, ms) * c.GST_MSECOND;
        srccaps = c.gst_caps_new_empty_simple(c.gst_structure_get_name(s));
        _ = c.gst_structure_foreach_id_str(s, copyFixed, c.gst_caps_get_structure(srccaps, 0));
        c.gst_caps_unref(temp);
    }
    if (r.sinkcaps != null) {
        const s = c.gst_caps_get_structure(r.sinkcaps, 0);
        if (c.g_str_has_prefix(c.gst_structure_get_name(s), "video") != 0) {
            var num: c.gint = 0;
            var den: c.gint = 0;
            var has = c.gst_structure_get_fraction(s, "framerate", &num, &den) != 0;
            if (has and num == 0 and den == 1) has = c.gst_structure_get_fraction(s, "max-framerate", &num, &den) != 0;
            if (has) {
                var rate: f64 = 0;
                c.gst_util_fraction_to_double(num, den, &rate);
                var str: [c.G_ASCII_DTOSTR_BUF_SIZE]u8 = undefined;
                _ = c.g_ascii_dtostr(&str, str.len, rate);
                c.gst_structure_set(c.gst_caps_get_structure(srccaps, 0), "a-framerate", c.G_TYPE_STRING, &str, @as(?*anyopaque, null));
            }
        }
    }
    updateMaxPtime(p);
    res = syncExtensions(p, srccaps);
    if (res) res = el.padSetCaps(p.srcpad, srccaps);
    c.gst_caps_unref(srccaps);
    c.gst_caps_unref(templ);
    r.negotiate_called = true;
    if (!res) c.gst_pad_mark_reconfigure(p.srcpad);
    return res;
}

fn syncExtensions(p: *Pay, srccaps: [*c]c.GstCaps) bool {
    const r = priv(p);
    if (!hdrext.syncFromCaps(p, r.exts, sig_request, srccaps)) return false;
    el.lock(p);
    if (r.sinkcaps != null) {
        for (exts(p)) |e| {
            if (hdrext.gst_rtp_header_extension_set_non_rtp_sink_caps(@ptrCast(e), r.sinkcaps) == 0) {
                el.unlock(p);
                return false;
            }
        }
    }
    for (exts(p)) |e| _ = hdrext.gst_rtp_header_extension_set_caps_from_attributes(@ptrCast(e), srccaps);
    el.unlock(p);
    notifyExtensions(p);
    return true;
}

pub export fn gst_rtp_base_payload_is_filled(p: [*c]Pay, size: c.guint, duration: c.GstClockTime) c.gboolean {
    if (size > p[0].mtu) return 1;
    return @intFromBool(p[0].max_ptime != -1 and duration >= @as(u64, @bitCast(p[0].max_ptime)));
}

const Header = struct {
    pay: *Pay,
    ssrc: u32,
    seqnum: u16,
    pt: u8,
    dts: c.GstClockTime,
    pts: c.GstClockTime,
    offset: u64,
    rtptime: u32,
};

fn findTimestamp(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const h: *Header = @ptrCast(@alignCast(data));
    h.dts = b.*[0].dts;
    h.pts = b.*[0].pts;
    h.offset = b.*[0].offset;
    return @intFromBool(h.pts == NONE);
}

fn addExtension(p: *Pay, e: [*c]Ext) callconv(.c) void {
    const f = "gst_rtp_base_payload_add_extension";
    if (!that(gtype.instanceOf(e, hdrext.gst_rtp_header_extension_get_type()), f, "GST_IS_RTP_HEADER_EXTENSION (ext)")) return;
    if (!that(hdrext.gst_rtp_header_extension_get_id(e) > 0, f, "gst_rtp_header_extension_get_id (ext) > 0")) return;
    el.lock(p);
    c.g_ptr_array_add(priv(p).exts, c.gst_object_ref(e));
    c.gst_pad_mark_reconfigure(p.srcpad);
    el.unlock(p);
    notifyExtensions(p);
}

fn clearExtensions(p: *Pay) callconv(.c) void {
    el.lock(p);
    c.g_ptr_array_set_size(priv(p).exts, 0);
    el.unlock(p);
    notifyExtensions(p);
}

fn getExtensions(p: *Pay, out: [*c]c.GValue) void {
    el.lock(p);
    defer el.unlock(p);
    for (exts(p)) |e| {
        var v = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&v, hdrext.gst_rtp_header_extension_get_type());
        c.g_value_set_object(&v, e);
        c.gst_value_array_append_and_take_value(out, &v);
    }
}

const Writer = struct {
    pay: *Pay,
    flags: c.GstRTPHeaderExtensionFlags = c.GST_RTP_HEADER_EXTENSION_ONE_BYTE | c.GST_RTP_HEADER_EXTENSION_TWO_BYTE,
    output: [*c]c.GstBuffer,
    data: [*c]u8 = null,
    allocated: usize = 0,
    written: usize = 0,
    unit: usize = 0,
    abort: bool = false,

    fn size(w: *Writer, e: [*c]Ext) void {
        w.flags &= hdrext.gst_rtp_header_extension_get_supported_flags(e);
        const max = hdrext.gst_rtp_header_extension_get_max_size(e, priv(w.pay).input_meta);
        const id = hdrext.gst_rtp_header_extension_get_id(e);
        if (max > ONE_BYTE_MAX_SIZE or id > ONE_BYTE_MAX_ID) w.flags &= ~@as(c.GstRTPHeaderExtensionFlags, c.GST_RTP_HEADER_EXTENSION_ONE_BYTE);
        if (max > TWO_BYTE_MAX_SIZE or id > TWO_BYTE_MAX_ID) w.flags &= ~@as(c.GstRTPHeaderExtensionFlags, c.GST_RTP_HEADER_EXTENSION_TWO_BYTE);
        w.allocated += max;
    }

    fn write(w: *Writer, e: [*c]Ext) void {
        if (w.abort) return;
        const remaining = w.allocated - w.written - w.unit;
        const at = w.written + w.unit;
        const n = hdrext.gst_rtp_header_extension_write(e, priv(w.pay).input_meta, w.flags, w.output, w.data + at, remaining);
        if (n == 0) return;
        if (n < 0) {
            w.abort = true;
            return;
        }
        const len: usize = @intCast(n);
        if (len > remaining) {
            c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_ERROR, "Overflow detected writing rtp header extensions. One of the instances likely did not report a large enough maximum size. Memory corruption has occured. Aborting");
            w.abort = true;
            return;
        }
        const id = hdrext.gst_rtp_header_extension_get_id(e);
        const h = at - w.unit;
        const name = @as(*c.GstObject, @ptrCast(@alignCast(e))).name;
        if (w.flags & c.GST_RTP_HEADER_EXTENSION_ONE_BYTE != 0) {
            if (len > ONE_BYTE_MAX_SIZE) {
                c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Amount of data written by %s is larger than allowed with a one byte header.", name);
                w.abort = true;
                return;
            }
            w.data[h] = @truncate(((id & 0x0f) << 4) | ((len - 1) & 0x0f));
        } else if (w.flags & c.GST_RTP_HEADER_EXTENSION_TWO_BYTE != 0) {
            if (len > TWO_BYTE_MAX_SIZE) {
                c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Amount of data written by %s is larger than allowed with a two byte header.", name);
                w.abort = true;
                return;
            }
            w.data[h] = @truncate(id);
            w.data[h + 1] = @truncate(len);
        } else {
            c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Don't know how to write extension data with flags 0x%x!", w.flags);
            w.abort = true;
            return;
        }
        w.written += len + w.unit;
    }
};

fn words(n: usize) c.guint {
    return @intCast(n / 4 + @intFromBool(n % 4 != 0));
}

fn setHeaders(b: [*c][*c]c.GstBuffer, _: c.guint, data: c.gpointer) callconv(.c) c.gboolean {
    const h: *Header = @ptrCast(@alignCast(data));
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    if (buf.gst_rtp_buffer_map(b.*, c.GST_MAP_READWRITE, &rtp) == 0) return 0;
    buf.gst_rtp_buffer_set_ssrc(&rtp, h.ssrc);
    buf.gst_rtp_buffer_set_payload_type(&rtp, h.pt);
    buf.gst_rtp_buffer_set_seq(&rtp, h.seqnum);
    buf.gst_rtp_buffer_set_timestamp(&rtp, h.rtptime);
    const p = h.pay;
    const r = priv(p);
    el.lock(p);
    if (r.exts[0].len > 0 and r.input_meta != null) {
        var w = Writer{ .pay = p, .output = b.* };
        for (exts(p)) |e| w.size(@ptrCast(e));
        var pattern: u16 = 0;
        if (w.flags & c.GST_RTP_HEADER_EXTENSION_ONE_BYTE != 0) {
            w.unit = 1;
            w.flags &= ~@as(c.GstRTPHeaderExtensionFlags, c.GST_RTP_HEADER_EXTENSION_TWO_BYTE);
            pattern = 0xBEDE;
        } else if (w.flags & c.GST_RTP_HEADER_EXTENSION_TWO_BYTE != 0) {
            w.unit = 2;
            pattern = 0x1000;
        } else {
            el.unlock(p);
            buf.gst_rtp_buffer_unmap(&rtp);
            return 0;
        }
        var wl = words(w.unit * r.exts[0].len + w.allocated);
        _ = buf.gst_rtp_buffer_set_extension_data(&rtp, pattern, @truncate(wl));
        var ptr: c.gpointer = null;
        _ = buf.gst_rtp_buffer_get_extension_data(&rtp, null, &ptr, &wl);
        w.data = @ptrCast(ptr);
        w.allocated = @as(usize, wl) * 4;
        for (exts(p)) |e| w.write(@ptrCast(e));
        if (w.written > 0) {
            wl = words(w.written);
            @memset(w.data[w.written .. @as(usize, wl) * 4], 0);
            _ = buf.gst_rtp_buffer_set_extension_data(&rtp, pattern, @truncate(wl));
        } else buf.gst_rtp_buffer_remove_extension_data(&rtp);
    }
    el.unlock(p);
    buf.gst_rtp_buffer_unmap(&rtp);
    h.seqnum +%= 1;
    return 1;
}

fn dropSourceMeta(_: [*c]c.GstBuffer, m: [*c][*c]c.GstMeta, _: c.gpointer) callconv(.c) c.gboolean {
    if (m.*[0].info[0].api == meta.gst_rtp_source_meta_api_get_type()) m.* = null;
    return 1;
}

fn filterMeta(b: [*c][*c]c.GstBuffer, _: c.guint, _: c.gpointer) callconv(.c) c.gboolean {
    return c.gst_buffer_foreach_meta(b.*, dropSourceMeta, null);
}

fn preparePush(p: *Pay, obj: c.gpointer, list: bool) c.GstFlowReturn {
    if (p.clock_rate == 0) {
        elementError(p, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, "subclass did not specify clock-rate", "gst_rtp_base_payload_prepare_push", 2029);
        return c.GST_FLOW_ERROR;
    }
    const r = priv(p);
    p.seqnum = r.next_seqnum;
    var h = Header{ .pay = p, .seqnum = p.seqnum, .ssrc = p.current_ssrc, .pt = @truncate(p.pt), .dts = NONE, .pts = NONE, .offset = NONE, .rtptime = 0 };
    if (list) {
        _ = c.gst_buffer_list_foreach(@ptrCast(obj), findTimestamp, &h);
    } else {
        const b: [*c]c.GstBuffer = @ptrCast(@alignCast(obj));
        h.dts = b[0].dts;
        h.pts = b[0].pts;
        h.offset = b[0].offset;
    }
    if (r.perfect_rtptime and h.offset != NONE and r.base_offset != NONE) {
        const d = h.offset -% r.base_offset;
        h.rtptime = @truncate(p.ts_base +% r.base_rtime_hz +% d);
        r.running_time = @as(u64, @bitCast(r.base_rtime)) +% h.offset -% r.base_offset;
    } else if (h.pts != NONE) {
        const ns = if (r.onvif_no_rate_control or !r.scale_rtptime)
            c.gst_segment_to_stream_time(&p.segment, c.GST_FORMAT_TIME, h.pts)
        else
            c.gst_segment_to_running_time(&p.segment, c.GST_FORMAT_TIME, h.pts);
        var hz: u64 = 0;
        if (ns != NONE) {
            hz = c.gst_util_uint64_scale_int(ns, @intCast(p.clock_rate), c.GST_SECOND);
            r.base_offset = h.offset;
            r.base_rtime_hz = hz;
        }
        h.rtptime = @truncate(p.ts_base +% hz);
        r.running_time = if (r.perfect_rtptime) hz else ns;
    } else h.rtptime = p.timestamp;
    if (list) {
        _ = c.gst_buffer_list_foreach(@ptrCast(obj), setHeaders, &h);
        _ = c.gst_buffer_list_foreach(@ptrCast(obj), filterMeta, null);
        p.seqnum = h.seqnum -% 1;
    } else {
        var b: [*c]c.GstBuffer = @ptrCast(@alignCast(obj));
        _ = setHeaders(&b, 0, &h);
        _ = filterMeta(&b, 0, null);
    }
    r.next_seqnum = h.seqnum;
    p.timestamp = h.rtptime;
    if (c.g_atomic_int_compare_and_exchange(&r.notified_first_timestamp, 1, 0) != 0) {
        c.g_object_notify(@ptrCast(p), "timestamp");
        c.g_object_notify(@ptrCast(p), "seqnum");
    }
    return c.GST_FLOW_OK;
}

pub export fn gst_rtp_base_payload_push_list(p: [*c]Pay, list: ?*c.GstBufferList) c.GstFlowReturn {
    const res = preparePush(of(p), list, true);
    if (res != c.GST_FLOW_OK) {
        c.gst_mini_object_unref(@ptrCast(@alignCast(list)));
        return res;
    }
    flushPendingSegment(of(p));
    return c.gst_pad_push_list(p[0].srcpad, list);
}

pub export fn gst_rtp_base_payload_push(p: [*c]Pay, b: [*c]c.GstBuffer) c.GstFlowReturn {
    const res = preparePush(of(p), b, false);
    if (res != c.GST_FLOW_OK) {
        c.gst_buffer_unref(b);
        return res;
    }
    flushPendingSegment(of(p));
    return c.gst_pad_push(p[0].srcpad, b);
}

pub export fn gst_rtp_base_payload_allocate_output_buffer(p: [*c]Pay, len: c.guint, pad: u8, csrcs: u8) [*c]c.GstBuffer {
    const r = priv(p);
    if (r.input_meta != null) {
        const m = meta.gst_buffer_get_rtp_source_meta(r.input_meta);
        if (m != null) {
            const total = @min(@as(c.guint, csrcs) + m[0].csrc_count + @intFromBool(m[0].ssrc_valid != 0), 15);
            const b = buf.gst_rtp_buffer_new_allocate(len, pad, @intCast(total));
            var rtp = std.mem.zeroes(c.GstRTPBuffer);
            _ = buf.gst_rtp_buffer_map(b, c.GST_MAP_READWRITE, &rtp);
            var idx: c.guint = csrcs;
            var i: c.guint = 0;
            while (i < m[0].csrc_count and idx < 15) : ({
                i += 1;
                idx += 1;
            }) buf.gst_rtp_buffer_set_csrc(&rtp, @intCast(idx), m[0].csrc[i]);
            if (m[0].ssrc_valid != 0 and idx < 15) buf.gst_rtp_buffer_set_csrc(&rtp, @intCast(idx), m[0].ssrc);
            buf.gst_rtp_buffer_unmap(&rtp);
            return b;
        }
    }
    return buf.gst_rtp_buffer_new_allocate(len, pad, csrcs);
}

fn stats(p: *Pay) ?*c.GstStructure {
    const r = priv(p);
    return c.gst_structure_new("application/x-rtp-payload-stats", "clock-rate", c.G_TYPE_UINT, p.clock_rate, "running-time", c.G_TYPE_UINT64, r.running_time, "seqnum", c.G_TYPE_UINT, @as(c.guint, p.seqnum), "timestamp", c.G_TYPE_UINT, p.timestamp, "ssrc", c.G_TYPE_UINT, p.current_ssrc, "pt", c.G_TYPE_UINT, p.pt, "seqnum-offset", c.G_TYPE_UINT, @as(c.guint, p.seqnum_base), "timestamp-offset", c.G_TYPE_UINT, p.ts_base, @as(?*anyopaque, null));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = of(o);
    const r = priv(p);
    switch (id) {
        P.MTU => p.mtu = c.g_value_get_uint(v),
        P.PT => {
            p.pt = c.g_value_get_uint(v);
            r.pt_set = true;
        },
        P.SSRC => {
            p.ssrc = c.g_value_get_uint(v);
            r.ssrc_random = false;
        },
        P.TIMESTAMP_OFFSET => {
            p.ts_offset = @bitCast(c.g_value_get_uint(v));
            r.ts_offset_random = false;
        },
        P.SEQNUM_OFFSET => {
            const n = c.g_value_get_int(v);
            p.seqnum_offset = @truncate(n);
            r.seqnum_offset_random = n == -1;
        },
        P.MAX_PTIME => {
            r.prop_max_ptime = c.g_value_get_int64(v);
            updateMaxPtime(p);
        },
        P.MIN_PTIME => p.min_ptime = @bitCast(c.g_value_get_int64(v)),
        P.PERFECT_RTPTIME => r.perfect_rtptime = c.g_value_get_boolean(v) != 0,
        P.PTIME_MULTIPLE => p.ptime_multiple = @bitCast(c.g_value_get_int64(v)),
        P.SOURCE_INFO => gst_rtp_base_payload_set_source_info_enabled(p, c.g_value_get_boolean(v)),
        P.ONVIF_NO_RATE_CONTROL => r.onvif_no_rate_control = c.g_value_get_boolean(v) != 0,
        P.SCALE_RTPTIME => r.scale_rtptime = c.g_value_get_boolean(v) != 0,
        P.AUTO_HEADER_EXTENSION => r.auto_hdr_ext = c.g_value_get_boolean(v) != 0,
        else => el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 2242),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    const p = of(o);
    const r = priv(p);
    switch (id) {
        P.MTU => c.g_value_set_uint(v, p.mtu),
        P.PT => c.g_value_set_uint(v, p.pt),
        P.SSRC => c.g_value_set_uint(v, if (r.ssrc_random) std.math.maxInt(c.guint) else p.ssrc),
        P.TIMESTAMP_OFFSET => c.g_value_set_uint(v, if (r.ts_offset_random) std.math.maxInt(c.guint) else @as(u32, @bitCast(p.ts_offset))),
        P.SEQNUM_OFFSET => c.g_value_set_int(v, if (r.seqnum_offset_random) -1 else @as(u16, @bitCast(p.seqnum_offset))),
        P.MAX_PTIME => c.g_value_set_int64(v, p.max_ptime),
        P.MIN_PTIME => c.g_value_set_int64(v, @bitCast(p.min_ptime)),
        P.TIMESTAMP => c.g_value_set_uint(v, p.timestamp),
        P.SEQNUM => c.g_value_set_uint(v, p.seqnum),
        P.PERFECT_RTPTIME => c.g_value_set_boolean(v, @intFromBool(r.perfect_rtptime)),
        P.PTIME_MULTIPLE => c.g_value_set_int64(v, @bitCast(p.ptime_multiple)),
        P.STATS => c.g_value_take_boxed(v, stats(p)),
        P.SOURCE_INFO => c.g_value_set_boolean(v, gst_rtp_base_payload_is_source_info_enabled(p)),
        P.ONVIF_NO_RATE_CONTROL => c.g_value_set_boolean(v, @intFromBool(r.onvif_no_rate_control)),
        P.SCALE_RTPTIME => c.g_value_set_boolean(v, @intFromBool(r.scale_rtptime)),
        P.AUTO_HEADER_EXTENSION => c.g_value_set_boolean(v, @intFromBool(r.auto_hdr_ext)),
        P.EXTENSIONS => getExtensions(p, v),
        else => el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 2321),
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const p = of(e);
    const r = priv(p);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        c.gst_segment_init(&p.segment, c.GST_FORMAT_UNDEFINED);
        r.delay_segment = true;
        replaceEvent(&r.pending_segment, null);
        p.seqnum_base = if (r.seqnum_offset_random) @intCast(c.g_random_int_range(0, std.math.maxInt(i16))) else @bitCast(p.seqnum_offset);
        r.next_seqnum = p.seqnum_base;
        p.seqnum = p.seqnum_base;
        p.current_ssrc = if (r.ssrc_random) c.g_random_int() else p.ssrc;
        p.ts_base = if (r.ts_offset_random) c.g_random_int() else @bitCast(p.ts_offset);
        p.timestamp = p.ts_base;
        r.running_time = NONE;
        c.g_atomic_int_set(&r.notified_first_timestamp, 1);
        r.base_offset = NONE;
        r.negotiated = false;
        r.negotiate_called = false;
        replaceCaps(&r.subclass_srccaps, null);
        replaceCaps(&r.sinkcaps, null);
    }
    const ret = parent.?.change_state.?(e, t);
    switch (t) {
        c.GST_STATE_CHANGE_PLAYING_TO_PAUSED => c.g_atomic_int_set(&r.notified_first_timestamp, 1),
        c.GST_STATE_CHANGE_PAUSED_TO_READY => replaceEvent(&r.pending_segment, null),
        else => {},
    }
    return ret;
}

pub export fn gst_rtp_base_payload_set_source_info_enabled(p: [*c]Pay, enable: c.gboolean) void {
    priv(p).source_info = enable != 0;
}

pub export fn gst_rtp_base_payload_is_source_info_enabled(p: [*c]Pay) c.gboolean {
    return @intFromBool(priv(p).source_info);
}

pub export fn gst_rtp_base_payload_get_source_count(p: [*c]Pay, b: [*c]c.GstBuffer) c.guint {
    if (!that(b != null, "gst_rtp_base_payload_get_source_count", "buffer != NULL")) return 0;
    if (gst_rtp_base_payload_is_source_info_enabled(p) == 0) return 0;
    const m = meta.gst_buffer_get_rtp_source_meta(b);
    return if (m != null) meta.gst_rtp_source_meta_get_source_count(m) else 0;
}
