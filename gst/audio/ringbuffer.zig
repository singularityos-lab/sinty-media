const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const format = @import("format.zig");
const info_mod = @import("info.zig");
const channels_mod = @import("channels.zig");
const dsd = @import("dsd.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const RB = c.GstAudioRingBuffer;
const Class = c.GstAudioRingBufferClass;
const Spec = c.GstAudioRingBufferSpec;
const NONE: u64 = std.math.maxInt(u64);
const PATH = "../gst-libs/gst/audio/gstaudioringbuffer.c";

const STOPPED = c.GST_AUDIO_RING_BUFFER_STATE_STOPPED;
const PAUSED = c.GST_AUDIO_RING_BUFFER_STATE_PAUSED;
const STARTED = c.GST_AUDIO_RING_BUFFER_STATE_STARTED;
const ERROR = c.GST_AUDIO_RING_BUFFER_STATE_ERROR;

const Private = extern struct { segdone: u64, segbase: u64 };

var once: gtype.Once = .{};
var offset_: c.gint = 0;
var parent: ?*c.GObjectClass = null;

fn priv(b: anytype) *Private {
    return @ptrCast(@alignCast(@as([*c]RB, @ptrCast(@alignCast(b))).*.priv));
}

fn klass(b: anytype) *Class {
    return gtype.classPeek(Class, b);
}

fn isRB(b: anytype) bool {
    return gtype.instanceOf(b, gst_audio_ring_buffer_get_type());
}

fn lock(b: [*c]RB) void {
    c.g_mutex_lock(&b.*.object.lock);
}

fn unlock(b: [*c]RB) void {
    c.g_mutex_unlock(&b.*.object.lock);
}

fn signal(b: [*c]RB) void {
    c.g_cond_signal(&b.*.cond);
}

fn cas(p: *c.gint, old: c.gint, new: c.gint) bool {
    return @cmpxchgStrong(c.gint, p, old, new, .seq_cst, .seq_cst) == null;
}

fn aget(p: *c.gint) c.gint {
    return @atomicLoad(c.gint, p, .seq_cst);
}

fn aset(p: *c.gint, v: c.gint) void {
    @atomicStore(c.gint, p, v, .seq_cst);
}

fn get64(p: *u64) u64 {
    return @atomicLoad(u64, p, .seq_cst);
}

fn set64(p: *u64, v: u64) void {
    @atomicStore(u64, p, v, .seq_cst);
}

fn assertFail(line: c_int, comptime func: []const u8, comptime expr: []const u8) void {
    c.g_assertion_message_expr(check.DOMAIN, PATH, line, func ++ "", expr ++ "");
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const b: [*c]RB = @ptrCast(@alignCast(o));
    _ = c.gst_mini_object_replace(@ptrCast(&b.*.spec.caps), null);
    parent.?.dispose.?(o);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const b: [*c]RB = @ptrCast(@alignCast(o));
    c.g_cond_clear(&b.*.cond);
    c.g_free(b.*.empty_seg);
    if (b.*.cb_data_notify != null) b.*.cb_data_notify.?(b.*.cb_data);
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (offset_ != 0) c.g_type_class_adjust_private_offset(k, &offset_);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    const rc: *Class = @ptrCast(@alignCast(k));
    _ = c._gst_debug_category_new("ringbuffer", 0, "ringbuffer class");
    oc.dispose = dispose;
    oc.finalize = finalize;
    rc.clear_all = defaultClearAll;
    rc.commit = defaultCommit;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const b: [*c]RB = @ptrCast(@alignCast(inst));
    b.*.priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset_))));
    b.*.open = 0;
    b.*.acquired = 0;
    aset(&b.*.state, STOPPED);
    c.g_cond_init(&b.*.cond);
    b.*.waiting = 0;
    b.*.empty_seg = null;
    b.*.flushing = 1;
    b.*.segbase = 0;
    b.*.segdone = 0;
    priv(b).segbase = 0;
    priv(b).segdone = 0;
}

pub export fn gst_audio_ring_buffer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstAudioRingBuffer", Class, RB, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            offset_ = c.g_type_add_instance_private(t, @sizeOf(Private));
            return t;
        }
    }.f);
}

pub export fn gst_audio_ring_buffer_debug_spec_caps(_: [*c]Spec) void {}

pub export fn gst_audio_ring_buffer_debug_spec_buff(_: [*c]Spec) void {}

pub export fn gst_audio_ring_buffer_parse_caps(spec: [*c]Spec, caps: [*c]c.GstCaps) c.gboolean {
    const st = c.gst_caps_get_structure(caps, 0);
    var info: c.GstAudioInfo = undefined;
    info_mod.gst_audio_info_init(&info);
    const mime = c.gst_structure_get_name(st);
    var i: c.gint = 0;
    const eq = struct {
        fn f(a: [*c]const u8, b: [*c]const u8) bool {
            return c.g_str_equal(a, b) != 0;
        }
    }.f;
    if (eq(mime, "audio/x-raw")) {
        if (info_mod.gst_audio_info_from_caps(&info, caps) == 0) return 0;
        spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW;
    } else if (eq(mime, "audio/x-alaw") or eq(mime, "audio/x-mulaw")) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0 or c.gst_structure_get_int(st, "channels", &info.channels) == 0) return 0;
        if (channels_mod.gst_audio_channel_positions_from_mask(info.channels, 0, @ptrCast(&info.position)) == 0) return 0;
        spec.*.type = if (eq(mime, "audio/x-alaw")) c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_A_LAW else c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MU_LAW;
        info.bpf = info.channels;
    } else if (eq(mime, "audio/x-iec958")) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0) return 0;
        spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_IEC958;
        info.bpf = 4;
    } else if (eq(mime, "audio/x-ac3") or eq(mime, "audio/x-eac3") or eq(mime, "audio/x-dts")) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0) return 0;
        _ = c.gst_structure_get_int(st, "channels", &info.channels);
        if (eq(mime, "audio/x-ac3")) {
            spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3;
            info.bpf = 4;
        } else if (eq(mime, "audio/x-eac3")) {
            spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3;
            info.bpf = 16;
        } else {
            spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS;
            info.bpf = 4;
        }
    } else if (eq(mime, "audio/mpeg") and c.gst_structure_get_int(st, "mpegaudioversion", &i) != 0 and (i == 1 or i == 2 or i == 3)) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0) return 0;
        _ = c.gst_structure_get_int(st, "channels", &info.channels);
        spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG;
        info.bpf = 1;
    } else if (eq(mime, "audio/mpeg") and c.gst_structure_get_int(st, "mpegversion", &i) != 0 and (i == 2 or i == 4) and (c.g_strcmp0(c.gst_structure_get_string(st, "stream-format"), "adts") == 0 or c.g_strcmp0(c.gst_structure_get_string(st, "stream-format"), "raw") == 0)) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0) return 0;
        _ = c.gst_structure_get_int(st, "channels", &info.channels);
        if (c.g_strcmp0(c.gst_structure_get_string(st, "stream-format"), "adts") == 0) {
            spec.*.type = if (i == 2) c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC else c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC;
        } else spec.*.type = if (i == 2) c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC_RAW else c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC_RAW;
        info.bpf = 1;
    } else if (eq(mime, "audio/x-flac")) {
        if (c.gst_structure_get_int(st, "rate", &info.rate) == 0) return 0;
        _ = c.gst_structure_get_int(st, "channels", &info.channels);
        spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_FLAC;
        info.bpf = 1;
    } else if (eq(mime, "audio/x-dsd")) {
        var di: c.GstDsdInfo = undefined;
        if (dsd.gst_dsd_info_from_caps(&di, caps) == 0) return 0;
        const w: c.gint = @intCast(dsd.gst_dsd_format_get_width(di.format));
        info.rate = @intCast(@divTrunc(@as(c.guint, @bitCast(di.rate)), @as(c.guint, @bitCast(w))));
        info.channels = di.channels;
        info.bpf = w * di.channels;
        const n: usize = @intCast(di.channels);
        const dst: [*]c.GstAudioChannelPosition = @ptrCast(&info.position);
        const src: [*]const c.GstAudioChannelPosition = @ptrCast(&di.positions);
        @memcpy(dst[0..n], src[0..n]);
        spec.*.ABI.abi.dsd_format = di.format;
        spec.*.type = c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DSD;
    } else return 0;
    _ = c.gst_mini_object_replace(@ptrCast(&spec.*.caps), @ptrCast(caps));
    if (!check.that(spec.*.latency_time != 0, "gst_audio_ring_buffer_parse_caps", "spec->latency_time != 0")) return 0;
    spec.*.segsize = @intCast(c.gst_util_uint64_scale(@bitCast(@as(i64, info.rate *% info.bpf)), spec.*.latency_time, c.GST_SECOND / c.GST_USECOND));
    spec.*.segsize -= @rem(spec.*.segsize, info.bpf);
    spec.*.segtotal = @intCast(spec.*.buffer_time / spec.*.latency_time);
    spec.*.seglatency = -1;
    spec.*.info = info;
    return 1;
}

pub export fn gst_audio_ring_buffer_convert(b: [*c]RB, src_fmt: c.GstFormat, src_val: c_long, dest_fmt: c.GstFormat, dest_val: [*c]c_long) c.gboolean {
    lock(b);
    const r = info_mod.gst_audio_info_convert(&b.*.spec.info, src_fmt, src_val, dest_fmt, dest_val);
    unlock(b);
    return r;
}

pub export fn gst_audio_ring_buffer_set_callback(b: [*c]RB, cb: c.GstAudioRingBufferCallback, data: c.gpointer) void {
    gst_audio_ring_buffer_set_callback_full(b, cb, data, null);
}

pub export fn gst_audio_ring_buffer_set_callback_full(b: [*c]RB, cb: c.GstAudioRingBufferCallback, data: c.gpointer, notify: c.GDestroyNotify) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_set_callback_full", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    lock(b);
    const old_notify = b.*.cb_data_notify;
    const old_data = b.*.cb_data;
    b.*.callback = cb;
    b.*.cb_data = data;
    b.*.cb_data_notify = notify;
    unlock(b);
    if (old_notify != null) old_notify.?(old_data);
}

pub export fn gst_audio_ring_buffer_open_device(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_open_device", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    var res: c.gboolean = 1;
    lock(b);
    defer unlock(b);
    if (b.*.open != 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Device for ring buffer %p already open, fix your code", b);
        return 1;
    }
    b.*.open = 1;
    if (b.*.acquired != 0) assertFail(641, "gst_audio_ring_buffer_open_device", "!buf->acquired");
    if (klass(b).open_device) |f| res = f(b);
    if (res == 0) b.*.open = 0;
    return res;
}

pub export fn gst_audio_ring_buffer_close_device(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_close_device", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    var res: c.gboolean = 1;
    lock(b);
    defer unlock(b);
    if (b.*.open == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Device for ring buffer %p already closed, fix your code", b);
        return 1;
    }
    if (b.*.acquired != 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Resources for ring buffer %p still acquired", b);
        return 0;
    }
    b.*.open = 0;
    if (klass(b).close_device) |f| res = f(b);
    if (res == 0) b.*.open = 1;
    return res;
}

pub export fn gst_audio_ring_buffer_device_is_open(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_device_is_open", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    return b.*.open;
}

pub export fn gst_audio_ring_buffer_acquire(b: [*c]RB, spec: [*c]Spec) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_acquire", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    var res: c.gboolean = 0;
    lock(b);
    defer unlock(b);
    if (b.*.open == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Device for %p not opened", b);
        return 0;
    }
    if (b.*.acquired != 0) return 1;
    b.*.acquired = 1;
    b.*.need_reorder = 0;
    if (klass(b).acquire) |f| res = f(b, spec);
    b.*.need_reorder = @intFromBool(b.*.need_reorder != 0 and b.*.spec.type == c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW);
    if (res == 0) {
        b.*.acquired = 0;
        return res;
    }
    const total: usize = @intCast(@max(spec.*.segtotal, 0));
    b.*.timestamps = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(u64) * total)));
    for (0..total) |i| b.*.timestamps[i] = NONE;
    const bpf = b.*.spec.info.bpf;
    if (bpf == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "invalid bytes_per_frame from acquire ringbuffer %p, fix the element", b);
        b.*.acquired = 0;
        return 0;
    }
    if (b.*.spec.seglatency == -1) b.*.spec.seglatency = b.*.spec.segtotal;
    const segsize = b.*.spec.segsize;
    b.*.samples_per_seg = @divTrunc(segsize, bpf);
    c.g_free(b.*.empty_seg);
    const n: usize = @intCast(segsize);
    b.*.empty_seg = @ptrCast(c.g_malloc(n));
    switch (b.*.spec.type) {
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW => format.gst_audio_format_info_fill_silence(b.*.spec.info.finfo, b.*.empty_seg, n),
        c.GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DSD => @memset(b.*.empty_seg[0..n], 0x69),
        else => @memset(b.*.empty_seg[0..n], 0),
    }
    return res;
}

pub export fn gst_audio_ring_buffer_release(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_release", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    _ = gst_audio_ring_buffer_stop(b);
    var res: c.gboolean = 0;
    lock(b);
    defer unlock(b);
    if (b.*.timestamps != null) {
        c.g_free(b.*.timestamps);
        b.*.timestamps = null;
    }
    if (b.*.acquired == 0) return 1;
    b.*.acquired = 0;
    if (b.*.open == 0) assertFail(922, "gst_audio_ring_buffer_release", "buf->open");
    if (klass(b).release) |f| res = f(b);
    if (cas(&b.*.waiting, 1, 0)) signal(b);
    if (res == 0) {
        b.*.acquired = 1;
        return res;
    }
    set64(&priv(b).segdone, 0);
    aset(&b.*.segdone, 0);
    priv(b).segbase = 0;
    b.*.segbase = 0;
    c.g_free(b.*.empty_seg);
    b.*.empty_seg = null;
    _ = c.gst_mini_object_replace(@ptrCast(&b.*.spec.caps), null);
    info_mod.gst_audio_info_init(&b.*.spec.info);
    return res;
}

pub export fn gst_audio_ring_buffer_is_acquired(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_is_acquired", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    return b.*.acquired;
}

pub export fn gst_audio_ring_buffer_activate(b: [*c]RB, active: c.gboolean) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_activate", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    if (active != 0 and b.*.acquired == 0) {
        c.g_log(check.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "Device for %p not acquired", b);
        return 0;
    }
    if (b.*.active == active) return 1;
    var res: c.gboolean = 1;
    if (klass(b).activate) |f| res = f(b, active);
    if (res == 0) return res;
    b.*.active = active;
    return res;
}

pub export fn gst_audio_ring_buffer_is_active(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_is_active", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    return b.*.active;
}

pub export fn gst_audio_ring_buffer_set_flushing(b: [*c]RB, flushing: c.gboolean) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_set_flushing", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    lock(b);
    b.*.flushing = flushing;
    if (flushing != 0) {
        _ = pauseUnlocked(b);
    } else gst_audio_ring_buffer_clear_all(b);
    unlock(b);
}

pub export fn gst_audio_ring_buffer_is_flushing(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_is_flushing", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 1;
    lock(b);
    defer unlock(b);
    return b.*.flushing;
}

pub export fn gst_audio_ring_buffer_start(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_start", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    if (b.*.flushing != 0 or b.*.acquired == 0 or aget(&b.*.may_start) == 0) return 0;
    var resuming = false;
    if (!cas(&b.*.state, STOPPED, STARTED)) {
        if (!cas(&b.*.state, PAUSED, STARTED)) return 1;
        resuming = true;
    }
    var res: c.gboolean = 1;
    if (resuming) {
        if (klass(b).@"resume") |f| res = f(b);
    } else if (klass(b).start) |f| res = f(b);
    if (res == 0) aset(&b.*.state, PAUSED);
    return res;
}

pub export fn gst_audio_ring_buffer_set_errored(b: [*c]RB) void {
    if (!cas(&b.*.state, STARTED, ERROR)) _ = cas(&b.*.state, PAUSED, ERROR);
}

fn pauseUnlocked(b: [*c]RB) c.gboolean {
    if (!cas(&b.*.state, STARTED, PAUSED)) return 1;
    if (cas(&b.*.waiting, 1, 0)) signal(b);
    var res: c.gboolean = 0;
    if (klass(b).pause) |f| res = f(b);
    if (res == 0) aset(&b.*.state, STARTED);
    return res;
}

pub export fn gst_audio_ring_buffer_pause(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_pause", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    if (b.*.flushing != 0 or b.*.acquired == 0) return 0;
    return pauseUnlocked(b);
}

pub export fn gst_audio_ring_buffer_stop(b: [*c]RB) c.gboolean {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_stop", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    lock(b);
    defer unlock(b);
    if (!cas(&b.*.state, STARTED, STOPPED)) {
        if (!cas(&b.*.state, PAUSED, STOPPED) and !cas(&b.*.state, ERROR, STOPPED)) return 1;
    }
    if (cas(&b.*.waiting, 1, 0)) signal(b);
    var res: c.gboolean = 0;
    if (klass(b).stop) |f| res = f(b);
    if (res == 0) aset(&b.*.state, STARTED);
    return res;
}

pub export fn gst_audio_ring_buffer_delay(b: [*c]RB) c.guint {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_delay", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    if (gst_audio_ring_buffer_is_acquired(b) == 0) return 0;
    return if (klass(b).delay) |f| f(b) else 0;
}

pub export fn gst_audio_ring_buffer_samples_done(b: [*c]RB) c_ulong {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_samples_done", "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    return get64(&priv(b).segdone) *% @as(u64, @bitCast(@as(i64, b.*.samples_per_seg)));
}

pub export fn gst_audio_ring_buffer_set_sample(b: [*c]RB, sample_in: c_ulong) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_set_sample", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    const sample: u64 = if (sample_in == NONE) 0 else sample_in;
    if (b.*.samples_per_seg == 0) return;
    const segdone = get64(&priv(b).segdone);
    priv(b).segbase = segdone -% sample / @as(u64, @bitCast(@as(i64, b.*.samples_per_seg)));
    b.*.segbase = @truncate(@as(i64, @bitCast(priv(b).segbase)));
    gst_audio_ring_buffer_clear_all(b);
}

pub export fn gst_audio_ring_buffer_set_segdone(b: [*c]RB, segdone: c_ulong) void {
    set64(&priv(b).segdone, segdone);
    aset(&b.*.segdone, @truncate(@as(i64, @bitCast(segdone))));
}

pub export fn gst_audio_ring_buffer_get_segdone(b: [*c]RB) c_ulong {
    return get64(&priv(b).segdone);
}

pub export fn gst_audio_ring_buffer_get_segbase(b: [*c]RB) c_ulong {
    return get64(&priv(b).segbase);
}

fn defaultClearAll(b: [*c]RB) callconv(.c) void {
    if (b.*.spec.segtotal <= 0) return;
    var i: c.gint = 0;
    while (i < b.*.spec.segtotal) : (i += 1) gst_audio_ring_buffer_clear(b, i);
}

pub export fn gst_audio_ring_buffer_clear_all(b: [*c]RB) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_clear_all", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    if (klass(b).clear_all) |f| f(b);
}

fn waitSegment(b: [*c]RB) bool {
    var wait = true;
    if (aget(&b.*.state) != STARTED) {
        if (aget(&b.*.may_start) == 0) return false;
        const segments = get64(&priv(b).segdone);
        _ = gst_audio_ring_buffer_start(b);
        if (get64(&priv(b).segdone) != segments) wait = false;
    }
    lock(b);
    defer unlock(b);
    if (b.*.flushing != 0 or aget(&b.*.state) != STARTED) {
        _ = cas(&b.*.waiting, 1, 0);
        return false;
    }
    if (wait and cas(&b.*.waiting, 0, 1)) {
        c.g_cond_wait(&b.*.cond, &b.*.object.lock);
        if (b.*.flushing != 0 or aget(&b.*.state) != STARTED) {
            _ = cas(&b.*.waiting, 1, 0);
            return false;
        }
    }
    return true;
}

const Ctx = struct {
    in_samples: c.gint,
    out_samples: c.gint,
    bpf: usize,
    bps: usize,
    channels: usize,
    map: [*c]const c.gint,
    reorder: bool,
    skip: bool,
    accum: *c.gint,
    inr: c.gint,
    outr: c.gint,

    fn put(self: *Ctx, d: [*]u8, s: [*]const u8, len: usize) void {
        if (self.skip) return;
        if (!self.reorder) {
            @memcpy(d[0..len], s[0..len]);
            return;
        }
        var off: usize = 0;
        while (off + self.bpf <= len) : (off += self.bpf) {
            for (0..self.channels) |i| @memcpy(d[off + @as(usize, @intCast(self.map[i])) * self.bps ..][0..self.bps], s[off + i * self.bps ..][0..self.bps]);
        }
        if (len < self.bpf) for (0..self.channels) |i| @memcpy(d[@as(usize, @intCast(self.map[i])) * self.bps ..][0..self.bps], s[i * self.bps ..][0..self.bps]);
    }
};

fn defaultCommit(b: [*c]RB, sample: [*c]c_ulong, data_in: [*c]u8, in_samples_in: c.gint, out_samples_in: c.gint, accum: [*c]c.gint) callconv(.c) c.guint {
    const fname = "default_commit";
    if (!check.that(b.*.memory != null, fname, "buf->memory != NULL")) return std.math.maxInt(c.guint);
    if (!check.that(data_in != null, fname, "data != NULL")) return std.math.maxInt(c.guint);
    const channels = b.*.spec.info.channels;
    const dest: [*]u8 = @ptrCast(b.*.memory);
    const segsize = b.*.spec.segsize;
    const segtotal = b.*.spec.segtotal;
    const bpf = b.*.spec.info.bpf;
    const sps: u64 = @bitCast(@as(i64, b.*.samples_per_seg));
    const reverse = out_samples_in < 0;
    var x = Ctx{ .in_samples = in_samples_in, .out_samples = @intCast(@abs(out_samples_in)), .bpf = @intCast(bpf), .bps = @intCast(@divTrunc(bpf, channels)), .channels = @intCast(channels), .map = @ptrCast(&b.*.channel_reorder_map), .reorder = b.*.need_reorder != 0, .skip = false, .accum = @ptrCast(accum), .inr = 0, .outr = 0 };
    const use_in = x.in_samples >= x.out_samples;
    x.inr = x.in_samples - 1;
    x.outr = x.out_samples - 1;
    const inr = x.inr;
    const outr = x.outr;
    var data: [*]u8 = @ptrCast(data_in);
    var data_end: [*]u8 = data + @as(usize, @intCast(bpf * inr));
    var writeseg = sample.* / sps;
    var sampleoff: u64 = (sample.* % sps) * @as(u64, @intCast(bpf));
    const ubpf: usize = @intCast(bpf);
    var started = true;
    while ((if (use_in) x.in_samples else x.out_samples) > 0) {
        while (true) {
            const segdone = get64(&priv(b).segdone) -% priv(b).segbase;
            const diff: i64 = @bitCast(writeseg -% segdone);
            if (diff < 0) {
                x.skip = true;
                break;
            }
            if (diff < segtotal) {
                x.skip = false;
                break;
            }
            if (!waitSegment(b)) {
                started = false;
                break;
            }
        }
        if (!started) break;
        const ws: u64 = writeseg % @as(u64, @intCast(segtotal));
        const avail: c.gint = @intCast(@min(@as(i64, segsize) - @as(i64, @intCast(sampleoff)), @as(i64, bpf) * x.out_samples));
        var d: [*]u8 = dest + @as(usize, @intCast(ws * @as(u64, @intCast(segsize)) + sampleoff));
        const d_end: [*]u8 = d + @as(usize, @intCast(avail));
        sample.* +%= @intCast(@divTrunc(avail, bpf));
        const dsb = @intFromPtr(d);
        if (inr == outr and !reverse) {
            const towrite: usize = @min(@intFromPtr(data_end) + ubpf - @intFromPtr(data), @intFromPtr(d_end) - @intFromPtr(d));
            x.put(d, data, towrite);
            x.in_samples -= @intCast(towrite / ubpf);
            x.out_samples -= @intCast(towrite / ubpf);
            data += towrite;
        } else if (!reverse) {
            const sb = @intFromPtr(data);
            if (inr >= outr) {
                while (@intFromPtr(data) <= @intFromPtr(data_end) and @intFromPtr(d) < @intFromPtr(d_end)) {
                    x.put(d, data, ubpf);
                    data += ubpf;
                    accum.* += outr;
                    if ((accum.* << 1) >= inr) {
                        accum.* -= inr;
                        d += ubpf;
                    }
                }
            } else {
                while (@intFromPtr(data) <= @intFromPtr(data_end) and @intFromPtr(d) < @intFromPtr(d_end)) {
                    x.put(d, data, ubpf);
                    d += ubpf;
                    accum.* += inr;
                    if ((accum.* << 1) >= outr) {
                        accum.* -= outr;
                        data += ubpf;
                    }
                }
            }
            x.in_samples -= @intCast((@intFromPtr(data) - sb) / ubpf);
            x.out_samples -= @intCast((@intFromPtr(d) - dsb) / ubpf);
        } else {
            const sb = @intFromPtr(data_end);
            if (inr >= outr) {
                while (@intFromPtr(data) <= @intFromPtr(data_end) and @intFromPtr(d) < @intFromPtr(d_end)) {
                    x.put(d, data_end, ubpf);
                    data_end -= ubpf;
                    accum.* += outr;
                    while (@intFromPtr(d) < @intFromPtr(d_end) and (accum.* << 1) >= inr) {
                        accum.* -= inr;
                        d += ubpf;
                    }
                }
            } else {
                while (@intFromPtr(data) <= @intFromPtr(data_end) and @intFromPtr(d) < @intFromPtr(d_end)) {
                    x.put(d, data_end, ubpf);
                    d += ubpf;
                    accum.* += inr;
                    while (@intFromPtr(data) <= @intFromPtr(data_end) and (accum.* << 1) >= outr) {
                        accum.* -= outr;
                        data_end -= ubpf;
                    }
                }
            }
            x.in_samples -= @intCast((sb - @intFromPtr(data_end)) / ubpf);
            x.out_samples -= @intCast((@intFromPtr(d) - dsb) / ubpf);
        }
        writeseg += 1;
        sampleoff = 0;
    }
    if (started) data = data_end + ubpf;
    const remaining: isize = @divTrunc(@as(isize, @bitCast(@intFromPtr(data_end))) - @as(isize, @bitCast(@intFromPtr(data))), @as(isize, @intCast(ubpf)));
    return @bitCast(@as(c.gint, @truncate(@as(isize, inr) - remaining)));
}

pub export fn gst_audio_ring_buffer_commit(b: [*c]RB, sample: [*c]c_ulong, data: [*c]u8, in_samples: c.gint, out_samples: c.gint, accum: [*c]c.gint) c.guint {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_commit", "GST_IS_AUDIO_RING_BUFFER (buf)")) return std.math.maxInt(c.guint);
    if (in_samples == 0 or out_samples == 0) return @bitCast(in_samples);
    return if (klass(b).commit) |f| f(b, sample, data, in_samples, out_samples, accum) else std.math.maxInt(c.guint);
}

pub export fn gst_audio_ring_buffer_read(b: [*c]RB, sample_in: c_ulong, data_in: [*c]u8, len: c.guint, timestamp: [*c]c.GstClockTime) c.guint {
    const fname = "gst_audio_ring_buffer_read";
    if (!check.that(isRB(b), fname, "GST_IS_AUDIO_RING_BUFFER (buf)")) return std.math.maxInt(c.guint);
    if (!check.that(b.*.memory != null, fname, "buf->memory != NULL")) return std.math.maxInt(c.guint);
    if (!check.that(data_in != null, fname, "data != NULL")) return std.math.maxInt(c.guint);
    const dest: [*]u8 = @ptrCast(b.*.memory);
    const segsize: u64 = @intCast(b.*.spec.segsize);
    const segtotal = b.*.spec.segtotal;
    const channels: usize = @intCast(b.*.spec.info.channels);
    const bpf: usize = @intCast(b.*.spec.info.bpf);
    const bps = bpf / channels;
    const sps: u64 = @bitCast(@as(i64, b.*.samples_per_seg));
    var to_read = len;
    var sample = sample_in;
    var data: [*]u8 = @ptrCast(data_in);
    var readseg: u64 = 0;
    outer: while (to_read > 0) {
        readseg = sample / sps;
        const sampleoff = sample % sps;
        var sampleslen: c.guint = 0;
        var empty = false;
        while (true) {
            const segdone = get64(&priv(b).segdone) -% priv(b).segbase;
            const diff: i64 = @bitCast(segdone -% readseg);
            if (diff >= segtotal) {
                sampleslen = @intCast(@min(sps, to_read));
                @memcpy(data[0 .. sampleslen * bpf], @as([*]const u8, @ptrCast(b.*.empty_seg))[0 .. sampleslen * bpf]);
                empty = true;
                break;
            }
            if (diff > 0) break;
            if (!waitSegment(b)) break :outer;
        }
        if (!empty) {
            readseg = readseg % @as(u64, @intCast(segtotal));
            sampleslen = @intCast(@min(sps - sampleoff, to_read));
            var ptr = dest + @as(usize, @intCast(readseg * segsize + sampleoff * bpf));
            if (b.*.need_reorder != 0) {
                for (0..sampleslen) |i| {
                    for (0..channels) |j| @memcpy(data[i * bpf + @as(usize, @intCast(b[0].channel_reorder_map[j])) * bps ..][0..bps], ptr[j * bps ..][0..bps]);
                    ptr += bpf;
                }
            } else @memcpy(data[0 .. sampleslen * bpf], ptr[0 .. sampleslen * bpf]);
        }
        to_read -= sampleslen;
        sample += sampleslen;
        data += sampleslen * bpf;
    } else {
        if (b.*.timestamps != null and timestamp != null) timestamp.* = b.*.timestamps[readseg % @as(u64, @intCast(segtotal))];
    }
    return len - to_read;
}

pub export fn gst_audio_ring_buffer_prepare_read(b: [*c]RB, segment: [*c]c.gint, readptr: [*c][*c]u8, len: [*c]c.gint) c.gboolean {
    const fname = "gst_audio_ring_buffer_prepare_read";
    if (!check.that(isRB(b), fname, "GST_IS_AUDIO_RING_BUFFER (buf)")) return 0;
    if (b.*.callback == null and aget(&b.*.state) != STARTED) return 0;
    if (!check.that(b.*.memory != null, fname, "buf->memory != NULL")) return 0;
    if (!check.that(segment != null, fname, "segment != NULL")) return 0;
    if (!check.that(readptr != null, fname, "readptr != NULL")) return 0;
    if (!check.that(len != null, fname, "len != NULL")) return 0;
    const segdone = get64(&priv(b).segdone);
    segment.* = @intCast(segdone % @as(u64, @intCast(b.*.spec.segtotal)));
    len.* = b.*.spec.segsize;
    readptr.* = b.*.memory + @as(usize, @intCast(segment.* * len.*));
    if (b.*.callback) |cb| cb(b, readptr.*, @intCast(len.*), b.*.cb_data);
    return 1;
}

pub export fn gst_audio_ring_buffer_advance(b: [*c]RB, advance: c.guint) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_advance", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    _ = @atomicRmw(u64, &priv(b).segdone, .Add, advance, .seq_cst);
    _ = @atomicRmw(c.gint, &b.*.segdone, .Add, @bitCast(advance), .seq_cst);
    if (cas(&b.*.waiting, 1, 0)) {
        lock(b);
        signal(b);
        unlock(b);
    }
}

pub export fn gst_audio_ring_buffer_clear(b: [*c]RB, segment_in: c.gint) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_clear", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    if (b.*.memory == null or b.*.empty_seg == null) return;
    const segment = @rem(segment_in, b.*.spec.segtotal);
    const n: usize = @intCast(b.*.spec.segsize);
    const data = b.*.memory + @as(usize, @intCast(segment)) * n;
    @memcpy(data[0..n], b.*.empty_seg[0..n]);
}

pub export fn gst_audio_ring_buffer_may_start(b: [*c]RB, allowed: c.gboolean) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_may_start", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    aset(&b.*.may_start, allowed);
}

pub export fn gst_audio_ring_buffer_set_channel_positions(b: [*c]RB, position: [*c]const c.GstAudioChannelPosition) void {
    const fname = "gst_audio_ring_buffer_set_channel_positions";
    if (!check.that(isRB(b), fname, "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    if (!check.that(b.*.acquired != 0, fname, "buf->acquired")) return;
    const channels = b.*.spec.info.channels;
    const n: usize = @intCast(@max(channels, 0));
    const to: [*]const c.GstAudioChannelPosition = @ptrCast(&b.*.spec.info.position);
    b.*.need_reorder = 0;
    if (std.mem.eql(c.GstAudioChannelPosition, position[0..n], to[0..n])) return;
    if (channels == 1) return;
    var all_none = true;
    for (0..n) |i| {
        if (position[i] != c.GST_AUDIO_CHANNEL_POSITION_NONE) all_none = false;
    }
    if (all_none) return;
    if (channels_mod.gst_audio_get_channel_reorder_map(channels, position, to, @ptrCast(&b.*.channel_reorder_map)) == 0) {
        check.reached("gstaudioringbuffer.c", 2357, fname);
        return;
    }
    for (0..n) |i| {
        if (b[0].channel_reorder_map[i] != @as(c.gint, @intCast(i))) {
            b.*.need_reorder = 1;
            break;
        }
    }
}

pub export fn gst_audio_ring_buffer_set_timestamp(b: [*c]RB, readseg: c.gint, timestamp: c.GstClockTime) void {
    if (!check.that(isRB(b), "gst_audio_ring_buffer_set_timestamp", "GST_IS_AUDIO_RING_BUFFER (buf)")) return;
    lock(b);
    defer unlock(b);
    if (b.*.acquired == 0) return;
    b.*.timestamps[@intCast(readseg)] = timestamp;
}
