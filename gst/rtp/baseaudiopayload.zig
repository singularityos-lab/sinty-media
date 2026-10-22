const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const buf = @import("buffer.zig");
const base = @import("basepayload.zig");
const that = buf.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Pay = c.GstRTPBaseAudioPayload;
const Class = c.GstRTPBaseAudioPayloadClass;
const BaseClass = c.GstRTPBasePayloadClass;
const PATH = "../gst-libs/gst/rtp/gstrtpbaseaudiopayload.c";
const NONE = el.NONE;
const PROP_BUFFER_LIST = 1;

const Mode = enum { unset, frame, sample };

const Private = struct {
    mode: Mode,
    adapter: ?*c.GstAdapter,
    fragment_size: c.guint,
    frame_duration_ns: c.GstClockTime,
    discont: bool,
    offset: u64,
    last_timestamp: c.GstClockTime,
    last_rtptime: u32,
    alignment: c.guint,
    cached_mtu: c.guint,
    cached_min_ptime: c.guint,
    cached_max_ptime: c.guint,
    cached_ptime: c.guint,
    cached_min_length: c.guint,
    cached_max_length: c.guint,
    cached_ptime_multiple: c.guint,
    cached_align: c.guint,
    cached_csrc_count: c.guint,
};

var once: gtype.Once = .{};
var offset: c.gint = 0;
var parent: ?*BaseClass = null;
var audio_tag: c.GQuark = 0;

fn of(p: anytype) *Pay {
    return @ptrCast(@alignCast(p));
}

fn priv(p: anytype) *Private {
    return @ptrCast(@alignCast(of(p).priv));
}

fn bp(p: *Pay) *c.GstRTPBasePayload {
    return &p.payload;
}

pub export fn gst_rtp_base_audio_payload_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(base.gst_rtp_base_payload_get_type, "GstRTPBaseAudioPayload", Class, Pay, classInit, @ptrCast(&init), 0);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(k, &offset);
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    audio_tag = c.g_quark_from_static_string("audio");
    const ok: *c.GObjectClass = @ptrCast(@alignCast(k));
    const ek: *c.GstElementClass = @ptrCast(@alignCast(k));
    const pk: *BaseClass = @ptrCast(@alignCast(k));
    ok.finalize = finalize;
    ok.set_property = setProperty;
    ok.get_property = getProperty;
    c.g_object_class_install_property(ok, PROP_BUFFER_LIST, c.g_param_spec_boolean("buffer-list", "Buffer List", "Use Buffer Lists", 0, c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS));
    ek.change_state = changeState;
    pk.handle_buffer = handleBuffer;
    pk.sink_event = sinkEvent;
    _ = c._gst_debug_category_new("rtpbaseaudiopayload", 0, "base audio RTP payloader");
}

fn init(p: *Pay, _: c.gpointer) callconv(.c) void {
    p.priv = @ptrCast(@as([*]u8, @ptrCast(p)) + @as(usize, @bitCast(@as(isize, offset))));
    priv(p).* = std.mem.zeroes(Private);
    p.frame_size = 0;
    p.frame_duration = 0;
    p.sample_size = 0;
    priv(p).adapter = c.gst_adapter_new();
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_object_unref(priv(o).adapter);
    @as(*c.GObjectClass, @ptrCast(parent)).finalize.?(o);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_BUFFER_LIST) el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 243);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_BUFFER_LIST) {
        c.g_value_set_boolean(v, 0);
    } else el.badPropertyAt(o, id, pspec, "GStreamer-RTP", PATH, 261);
}

fn setMode(p: [*c]Pay, comptime f: []const u8, m: Mode) void {
    if (!that(p != null, f, "rtpbaseaudiopayload != NULL")) return;
    const unset = priv(p).mode == .unset;
    if (!that(unset, f, "rtpbaseaudiopayload->priv->time_to_bytes == NULL")) return;
    priv(p).mode = m;
}

pub export fn gst_rtp_base_audio_payload_set_frame_based(p: [*c]Pay) void {
    setMode(p, "gst_rtp_base_audio_payload_set_frame_based", .frame);
}

pub export fn gst_rtp_base_audio_payload_set_sample_based(p: [*c]Pay) void {
    setMode(p, "gst_rtp_base_audio_payload_set_sample_based", .sample);
}

pub export fn gst_rtp_base_audio_payload_set_frame_options(p: [*c]Pay, duration: c.gint, size: c.gint) void {
    if (!that(p != null, "gst_rtp_base_audio_payload_set_frame_options", "rtpbaseaudiopayload != NULL")) return;
    const r = priv(p);
    p[0].frame_duration = duration;
    r.frame_duration_ns = @as(u64, @bitCast(@as(i64, duration))) *% c.GST_MSECOND;
    p[0].frame_size = size;
    r.alignment = @bitCast(size);
    c.gst_adapter_clear(r.adapter);
}

pub export fn gst_rtp_base_audio_payload_set_sample_options(p: [*c]Pay, size: c.gint) void {
    if (!that(p != null, "gst_rtp_base_audio_payload_set_sample_options", "rtpbaseaudiopayload != NULL")) return;
    gst_rtp_base_audio_payload_set_samplebits_options(p, size * 8);
}

pub export fn gst_rtp_base_audio_payload_set_samplebits_options(p: [*c]Pay, bits: c.gint) void {
    if (!that(p != null, "gst_rtp_base_audio_payload_set_samplebits_options", "rtpbaseaudiopayload != NULL")) return;
    const r = priv(p);
    p[0].sample_size = bits;
    var frag: c.guint = @bitCast(bits);
    while (frag % 8 != 0) frag +%= frag;
    r.fragment_size = frag / 8;
    r.alignment = r.fragment_size;
    c.gst_adapter_clear(r.adapter);
}

fn framesIn(p: *Pay, bytes: u64) u64 {
    const size: u64 = @intCast(p.frame_size);
    return bytes / size + @intFromBool(bytes % size != 0);
}

fn bitsScale(p: *Pay, bytes: u64) u64 {
    if (p.sample_size == 8) return bytes;
    return c.gst_util_uint64_scale_int(bytes, 8, p.sample_size);
}

fn bytesToTime(p: *Pay, bytes: u64) c.GstClockTime {
    return switch (priv(p).mode) {
        .frame => framesIn(p, bytes) *% priv(p).frame_duration_ns,
        else => c.gst_util_uint64_scale_int(bitsScale(p, bytes), c.GST_SECOND, @intCast(bp(p).clock_rate)),
    };
}

fn bytesToRtptime(p: *Pay, bytes: u64) u32 {
    return switch (priv(p).mode) {
        .frame => @truncate(c.gst_util_uint64_scale_int(framesIn(p, bytes) *% priv(p).frame_duration_ns, @intCast(bp(p).clock_rate), c.GST_SECOND)),
        else => @truncate(bitsScale(p, bytes)),
    };
}

fn timeToBytes(p: *Pay, t: c.GstClockTime) u64 {
    switch (priv(p).mode) {
        .frame => return c.gst_util_uint64_scale(t, @intCast(p.frame_size), priv(p).frame_duration_ns),
        else => {
            const samples = c.gst_util_uint64_scale_int(t, @intCast(bp(p).clock_rate), c.GST_SECOND);
            if (p.sample_size == 8) return samples;
            return c.gst_util_uint64_scale_int(samples, p.sample_size, 8);
        },
    }
}

fn setMeta(p: *Pay, b: [*c]c.GstBuffer, len: c.guint, ts: c.GstClockTime) void {
    const r = priv(p);
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    _ = buf.gst_rtp_buffer_map(b, c.GST_MAP_WRITE, &rtp);
    buf.gst_rtp_buffer_set_payload_type(&rtp, @truncate(bp(p).pt));
    if (r.discont) {
        buf.gst_rtp_buffer_set_marker(&rtp, 1);
        b[0].mini_object.flags |= c.GST_BUFFER_FLAG_DISCONT;
        r.discont = false;
    }
    buf.gst_rtp_buffer_unmap(&rtp);
    b[0].pts = ts;
    b[0].offset = bytesToRtptime(p, r.offset);
    r.offset += len;
    b[0].duration = bytesToTime(p, len);
    r.last_rtptime = @truncate(b[0].offset);
    r.last_timestamp = ts;
}

pub export fn gst_rtp_base_audio_payload_push(p: [*c]Pay, data: [*c]const u8, len: c.guint, ts: c.GstClockTime) c.GstFlowReturn {
    const out = base.gst_rtp_base_payload_allocate_output_buffer(bp(of(p)), len, 0, 0);
    var rtp = std.mem.zeroes(c.GstRTPBuffer);
    _ = buf.gst_rtp_buffer_map(out, c.GST_MAP_WRITE, &rtp);
    const dst: [*]u8 = @ptrCast(buf.gst_rtp_buffer_get_payload(&rtp));
    @memcpy(dst[0..len], data[0..len]);
    buf.gst_rtp_buffer_unmap(&rtp);
    setMeta(of(p), out, len, ts);
    return base.gst_rtp_base_payload_push(bp(of(p)), out);
}

fn copyMeta(in: [*c]c.GstBuffer, m: [*c][*c]c.GstMeta, data: c.gpointer) callconv(.c) c.gboolean {
    const out: [*c]c.GstBuffer = @ptrCast(@alignCast(data));
    const info = m.*[0].info;
    const tags = c.gst_meta_api_type_get_tags(info[0].api);
    const plain = tags == null or (c.g_strv_length(@ptrCast(@constCast(tags))) == 1 and c.gst_meta_api_type_has_tag(info[0].api, audio_tag) != 0);
    if (info[0].transform_func != null and plain) {
        var copy = c.GstMetaTransformCopy{ .region = 0, .offset = 0, .size = std.math.maxInt(usize) };
        _ = info[0].transform_func.?(out, m.*, in, c._gst_meta_transform_copy, &copy);
    }
    return 1;
}

fn pushBuffer(p: *Pay, b: [*c]c.GstBuffer, ts: c.GstClockTime) c.GstFlowReturn {
    const len: c.guint = @intCast(c.gst_buffer_get_size(b));
    var out = base.gst_rtp_base_payload_allocate_output_buffer(bp(p), 0, 0, 0);
    setMeta(p, out, len, ts);
    _ = c.gst_buffer_foreach_meta(b, copyMeta, out);
    out = c.gst_buffer_append(out, b);
    return base.gst_rtp_base_payload_push(bp(p), out);
}

pub export fn gst_rtp_base_audio_payload_flush(p: [*c]Pay, length: c.guint, timestamp: c.GstClockTime) c.GstFlowReturn {
    const pay = of(p);
    const r = priv(pay);
    var len = length;
    var ts = timestamp;
    if (len == std.math.maxInt(c.guint)) len = @intCast(c.gst_adapter_available(r.adapter));
    if (len == 0) return c.GST_FLOW_OK;
    if (ts == NONE) {
        var distance: u64 = 0;
        ts = c.gst_adapter_prev_pts(r.adapter, &distance);
        if (ts != NONE and distance > 0) ts +%= bytesToTime(pay, distance);
    }
    var out = base.gst_rtp_base_payload_allocate_output_buffer(bp(pay), 0, 0, 0);
    const chunk = c.gst_adapter_take_buffer_fast(r.adapter, len);
    _ = c.gst_buffer_foreach_meta(chunk, copyMeta, out);
    out = c.gst_buffer_append(out, chunk);
    setMeta(pay, out, len, ts);
    return base.gst_rtp_base_payload_push(bp(pay), out);
}

fn alignDown(v: c.guint, n: c.guint) c.guint {
    return v - v % n;
}

fn lengths(p: *Pay, csrcs: c.guint, min: *c.guint, max: *c.guint, al: *c.guint) bool {
    const r = priv(p);
    const b = bp(p);
    if (r.alignment == 0) return false;
    const mtu = b.mtu;
    if (r.cached_mtu == mtu and r.cached_ptime_multiple == b.ptime_multiple and r.cached_ptime == b.ptime and @as(i64, r.cached_max_ptime) == b.max_ptime and r.cached_min_ptime == b.min_ptime and r.cached_csrc_count >= csrcs) {
        min.* = r.cached_min_length;
        max.* = r.cached_max_length;
        al.* = r.cached_align;
        return true;
    }
    const mult: c.guint = @truncate(timeToBytes(p, b.ptime_multiple));
    al.* = alignDown(@max(r.alignment, mult), r.alignment);
    const maxptime: c.guint = if (b.max_ptime != -1) @truncate(timeToBytes(p, @bitCast(b.max_ptime))) else std.math.maxInt(c.guint);
    var max_mtu = buf.gst_rtp_buffer_calc_payload_len(mtu, 0, @truncate(csrcs));
    max_mtu = alignDown(max_mtu, al.*);
    max.* = @min(max_mtu, maxptime);
    const minptime: c.guint = @truncate(timeToBytes(p, b.min_ptime));
    min.* = @max(minptime, al.*);
    if (min.* > max.*) min.* = max.*;
    if (b.ptime != 0) {
        var n: c.guint = @truncate(timeToBytes(p, b.ptime));
        n = @min(max.*, @max(min.*, n));
        min.* = n;
        max.* = n;
    }
    r.cached_mtu = mtu;
    r.cached_ptime = @truncate(b.ptime);
    r.cached_min_ptime = @truncate(b.min_ptime);
    r.cached_max_ptime = @truncate(@as(u64, @bitCast(b.max_ptime)));
    r.cached_ptime_multiple = @truncate(b.ptime_multiple);
    r.cached_min_length = min.*;
    r.cached_max_length = max.*;
    r.cached_align = al.*;
    r.cached_csrc_count = csrcs;
    return true;
}

fn handleBuffer(bb: [*c]c.GstRTPBasePayload, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const p = of(bb);
    const r = priv(p);
    var ret: c.GstFlowReturn = c.GST_FLOW_OK;
    const ts = b[0].pts;
    const fl = b[0].mini_object.flags;
    if (fl & (c.GST_BUFFER_FLAG_DISCONT | c.GST_BUFFER_FLAG_RESYNC) != 0) {
        ret = gst_rtp_base_audio_payload_flush(p, std.math.maxInt(c.guint), NONE);
        r.discont = true;
        if (r.last_timestamp != NONE and ts != NONE and ts > r.last_timestamp) r.offset += timeToBytes(p, ts - r.last_timestamp);
    }
    var min: c.guint = 0;
    var max: c.guint = 0;
    var al: c.guint = 0;
    if (!lengths(p, base.gst_rtp_base_payload_get_source_count(bp(p), b), &min, &max, &al)) {
        el.errAt(p, .stream, c.GST_STREAM_ERROR_NOT_IMPLEMENTED, null, c.g_strdup("subclass did not configure us properly"), "gst-plugins-base-1.0", PATH, "gst_rtp_base_audio_payload_handle_buffer", 941);
        c.gst_buffer_unref(b);
        return c.GST_FLOW_ERROR;
    }
    const size: c.guint = @intCast(c.gst_buffer_get_size(b));
    var available: c.guint = @intCast(c.gst_adapter_available(r.adapter));
    if (available == 0 and size >= min and size <= max and size % al == 0) return pushBuffer(p, b, ts);
    c.gst_adapter_push(r.adapter, b);
    available += size;
    while (available >= min) {
        const len = alignDown(@min(max, available), al);
        ret = gst_rtp_base_audio_payload_flush(p, len, NONE);
        available -= len;
    }
    return ret;
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const r = priv(e);
    if (t == c.GST_STATE_CHANGE_READY_TO_PAUSED) {
        r.cached_mtu = std.math.maxInt(c.guint);
        r.last_rtptime = std.math.maxInt(u32);
        r.last_timestamp = NONE;
    }
    const ek: *c.GstElementClass = @ptrCast(@alignCast(parent));
    const ret = ek.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) c.gst_adapter_clear(r.adapter);
    return ret;
}

fn sinkEvent(bb: [*c]c.GstRTPBasePayload, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    const p = of(bb);
    switch (ev[0].type) {
        c.GST_EVENT_EOS => _ = gst_rtp_base_audio_payload_flush(p, std.math.maxInt(c.guint), NONE),
        c.GST_EVENT_FLUSH_STOP => c.gst_adapter_clear(priv(p).adapter),
        else => {},
    }
    return parent.?.sink_event.?(bb, ev);
}

pub export fn gst_rtp_base_audio_payload_get_adapter(p: [*c]Pay) ?*c.GstAdapter {
    const a = priv(p).adapter;
    if (a != null) _ = c.g_object_ref(a);
    return a;
}
