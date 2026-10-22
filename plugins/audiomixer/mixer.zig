const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pads = @import("pads.zig");

const FILE = "../gst/audiomixer/gstaudiomixer.c";
const PROP_PAD_VOLUME = 1;
const PROP_PAD_MUTE = 2;
const LIVEADDER_PROP_LATENCY = 1;

const SRC_CAPS = "audio/x-raw, format = (string) { S32LE, U32LE, S16LE, U16LE, S8, U8, F32LE, F64LE }, rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = interleaved";
const SINK_CAPS = "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout=interleaved";

pub const Pad = extern struct {
    parent: pads.CPad,
    volume: f64,
    volume_i32: c.gint,
    volume_i16: c.gint,
    volume_i8: c.gint,
    mute: c.gboolean,
};

const PadClass = extern struct {
    parent: c.GstAudioAggregatorConvertPadClass,
};

const Self = extern struct {
    parent: c.GstAudioAggregator,
};

const Class = extern struct {
    parent: c.GstAudioAggregatorClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, SRC_CAPS);
var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, SINK_CAPS);
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var live_once: cm.Once = .{};
var parent: ?*c.GstElementClass = null;
var live_parent: ?*c.GObjectClass = null;
var init_done: ?*anyopaque = null;

fn pad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

pub fn elementInit() void {
    if (c.g_once_init_enter_pointer(@ptrCast(&init_done)) != 0) {
        _ = c._gst_debug_category_new("audiomixer", 0, "audio mixing element");
        c.g_once_init_leave_pointer(@ptrCast(&init_done), @ptrFromInt(1));
    }
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = pad(o);
    switch (id) {
        PROP_PAD_VOLUME => c.g_value_set_double(v, p.volume),
        PROP_PAD_MUTE => c.g_value_set_boolean(v, p.mute),
        else => cm.warnInvalid(FILE, o, id, spec, 109),
    }
}

fn padSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const p = pad(o);
    switch (id) {
        PROP_PAD_VOLUME => {
            cm.lock(p);
            p.volume = c.g_value_get_double(v);
            p.volume_i8 = @intFromFloat(p.volume * 8);
            p.volume_i16 = @intFromFloat(p.volume * 2048);
            p.volume_i32 = @intFromFloat(p.volume * 134217728);
            cm.unlock(p);
        },
        PROP_PAD_MUTE => {
            cm.lock(p);
            p.mute = c.g_value_get_boolean(v);
            cm.unlock(p);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 135),
    }
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSetProperty;
    oc.get_property = padGetProperty;
    const flags = cm.RW | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_PAD_VOLUME, c.g_param_spec_double("volume", "Volume", "Volume of this pad", 0.0, 10.0, 1.0, flags));
    c.g_object_class_install_property(oc, PROP_PAD_MUTE, c.g_param_spec_boolean("mute", "Mute", "Mute this pad", 0, flags));
}

fn padInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const p = pad(inst);
    p.volume = 1.0;
    p.mute = 0;
}

pub fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_aggregator_convert_pad_get_type(), "GstAudioMixerPad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

pub fn ftz32(x: f32) f32 {
    const b: u32 = @bitCast(x);
    return if (b & 0x7f800000 == 0) @bitCast(b & 0x80000000) else x;
}

pub fn ftz64(x: f64) f64 {
    const b: u64 = @bitCast(x);
    return if (b & 0x7ff0000000000000 == 0) @bitCast(b & 0x8000000000000000) else x;
}

pub fn sat(comptime T: type, x: anytype) T {
    return @intCast(std.math.clamp(x, std.math.minInt(T), std.math.maxInt(T)));
}

pub fn addPlain(comptime T: type, d: [*]u8, s: [*]const u8, n: usize) void {
    const dd: [*]align(1) T = @ptrCast(d);
    const ss: [*]align(1) const T = @ptrCast(s);
    for (0..n) |i| {
        dd[i] = switch (T) {
            f32 => ftz32(ftz32(dd[i]) + ftz32(ss[i])),
            f64 => ftz64(ftz64(dd[i]) + ftz64(ss[i])),
            else => dd[i] +| ss[i],
        };
    }
}

pub fn addScaled(comptime T: type, comptime S: type, comptime W: type, comptime shift: u6, d: [*]u8, s: [*]const u8, vol: c.gint, n: usize) void {
    const dd: [*]align(1) T = @ptrCast(d);
    const ss: [*]align(1) const T = @ptrCast(s);
    const bias: T = if (T == S) 0 else @as(T, 1) << (@bitSizeOf(T) - 1);
    const p: S = @truncate(vol);
    for (0..n) |i| {
        const x: S = @bitCast(ss[i] ^ bias);
        const t: W = (@as(W, x) * @as(W, p)) >> shift;
        const y: T = @as(T, @bitCast(sat(S, t))) ^ bias;
        dd[i] +|= y;
    }
}

pub fn addFloat(comptime T: type, d: [*]u8, s: [*]const u8, vol: f64, n: usize) void {
    const dd: [*]align(1) T = @ptrCast(d);
    const ss: [*]align(1) const T = @ptrCast(s);
    const f = if (T == f32) ftz32 else ftz64;
    const p: T = f(@floatCast(vol));
    for (0..n) |i| {
        const t = f(f(ss[i]) * p);
        dd[i] = f(f(dd[i]) + t);
    }
}

pub fn volumeScaled(comptime T: type, comptime S: type, comptime W: type, comptime shift: u6, d: [*]u8, vol: c.gint, n: usize) void {
    const dd: [*]align(1) T = @ptrCast(d);
    const bias: T = if (T == S) 0 else @as(T, 1) << (@bitSizeOf(T) - 1);
    const p: S = @truncate(vol);
    for (0..n) |i| {
        const x: S = @bitCast(dd[i] ^ bias);
        const t: W = (@as(W, x) * @as(W, p)) >> shift;
        dd[i] = @as(T, @bitCast(sat(S, t))) ^ bias;
    }
}

pub fn volumeFloat(comptime T: type, d: [*]u8, vol: f64, n: usize) void {
    const dd: [*]align(1) T = @ptrCast(d);
    const f = if (T == f32) ftz32 else ftz64;
    const p: T = f(@floatCast(vol));
    for (0..n) |i| dd[i] = f(f(dd[i]) * p);
}

fn aggregateOne(aagg: [*c]c.GstAudioAggregator, apad: ?*c.GstAudioAggregatorPad, in: [*c]c.GstBuffer, in_off: c.guint, out: [*c]c.GstBuffer, out_off: c.guint, frames: c.guint) callconv(.c) c.gboolean {
    const p = pad(apad);
    const agg: *c.GstAggregator = @ptrCast(@alignCast(aagg));
    const srcpad = pads.apad(agg.srcpad);
    cm.lock(aagg);
    cm.lock(apad);
    defer {
        cm.unlock(apad);
        cm.unlock(aagg);
    }
    if (p.mute != 0 or p.volume < std.math.floatMin(f64)) return 0;
    const bpf: usize = @intCast(srcpad.info.bpf);
    var omap: c.GstMapInfo = undefined;
    var imap: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(out, &omap, c.GST_MAP_READWRITE);
    _ = c.gst_buffer_map(in, &imap, c.GST_MAP_READ);
    const d: [*]u8 = omap.data + out_off * bpf;
    const s: [*]const u8 = imap.data + in_off * bpf;
    const n = @as(usize, frames) * @as(usize, @intCast(srcpad.info.channels));
    const fmt = srcpad.info.finfo.*.format;
    if (p.volume == 1.0) {
        switch (fmt) {
            c.GST_AUDIO_FORMAT_U8 => addPlain(u8, d, s, n),
            c.GST_AUDIO_FORMAT_S8 => addPlain(i8, d, s, n),
            c.GST_AUDIO_FORMAT_U16LE => addPlain(u16, d, s, n),
            c.GST_AUDIO_FORMAT_S16LE => addPlain(i16, d, s, n),
            c.GST_AUDIO_FORMAT_U32LE => addPlain(u32, d, s, n),
            c.GST_AUDIO_FORMAT_S32LE => addPlain(i32, d, s, n),
            c.GST_AUDIO_FORMAT_F32LE => addPlain(f32, d, s, n),
            c.GST_AUDIO_FORMAT_F64LE => addPlain(f64, d, s, n),
            else => unreachable,
        }
    } else {
        switch (fmt) {
            c.GST_AUDIO_FORMAT_U8 => addScaled(u8, i8, i16, 3, d, s, p.volume_i8, n),
            c.GST_AUDIO_FORMAT_S8 => addScaled(i8, i8, i16, 3, d, s, p.volume_i8, n),
            c.GST_AUDIO_FORMAT_U16LE => addScaled(u16, i16, i32, 11, d, s, p.volume_i16, n),
            c.GST_AUDIO_FORMAT_S16LE => addScaled(i16, i16, i32, 11, d, s, p.volume_i16, n),
            c.GST_AUDIO_FORMAT_U32LE => addScaled(u32, i32, i64, 27, d, s, p.volume_i32, n),
            c.GST_AUDIO_FORMAT_S32LE => addScaled(i32, i32, i64, 27, d, s, p.volume_i32, n),
            c.GST_AUDIO_FORMAT_F32LE => addFloat(f32, d, s, p.volume, n),
            c.GST_AUDIO_FORMAT_F64LE => addFloat(f64, d, s, p.volume, n),
            else => unreachable,
        }
    }
    c.gst_buffer_unmap(in, &imap);
    c.gst_buffer_unmap(out, &omap);
    return 1;
}

fn requestNewPad(el: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, name: [*c]const u8, caps: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const p = parent.?.request_new_pad.?(el, templ, name, caps);
    if (p == null) return null;
    c.gst_child_proxy_child_added(@ptrCast(el), @ptrCast(@alignCast(p)), cm.obj(p).name);
    return p;
}

fn releasePad(el: [*c]c.GstElement, p: ?*c.GstPad) callconv(.c) void {
    c.gst_child_proxy_child_removed(@ptrCast(el), @ptrCast(@alignCast(p)), cm.obj(p).name);
    parent.?.release_pad.?(el, p);
}

pub fn childByIndex(cp: ?*c.GstChildProxy, index: c.guint) callconv(.c) [*c]c.GObject {
    cm.lock(cp);
    defer cm.unlock(cp);
    const o: [*c]c.GObject = @ptrCast(@alignCast(c.g_list_nth_data(@as(*c.GstElement, @ptrCast(@alignCast(cp))).sinkpads, index)));
    if (o != null) _ = c.gst_object_ref(o);
    return o;
}

pub fn childrenCount(cp: ?*c.GstChildProxy) callconv(.c) c.guint {
    cm.lock(cp);
    defer cm.unlock(cp);
    return @as(*c.GstElement, @ptrCast(@alignCast(cp))).numsinkpads;
}

fn proxyInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(g));
    i.get_child_by_index = childByIndex;
    i.get_children_count = childrenCount;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_t, c.gst_audio_aggregator_convert_pad_get_type());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.gst_element_class_set_static_metadata(ec, "AudioMixer", "Generic/Audio", "Mixes multiple audio streams", "Sebastian Dröge <sebastian@centricular.com>");
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    @as(*c.GstAudioAggregatorClass, @ptrCast(@alignCast(k))).aggregate_one_buffer = aggregateOne;
    c.gst_type_mark_as_plugin_api(padType(), 0);
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_audio_aggregator_get_type(), "GstAudioMixer", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    elementInit();
    return c.gst_element_register(p, "audiomixer", c.GST_RANK_NONE, getType()) != 0;
}

fn latencySpec() [*c]c.GParamSpec {
    return c.g_object_class_find_property(live_parent, "latency");
}

fn liveSetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != LIVEADDER_PROP_LATENCY) return cm.warnInvalid("../gst/audiomixer/gstliveadder.c", o, id, spec, 87);
    const ps = latencySpec();
    const owner: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(ps.*.owner_type)));
    var x = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&x, c.G_TYPE_UINT64);
    c.g_value_set_uint64(&x, @as(u64, c.g_value_get_uint(v)) * @as(u64, c.GST_MSECOND));
    owner.set_property.?(o, ps.*.param_id, &x, ps);
}

fn liveGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != LIVEADDER_PROP_LATENCY) return cm.warnInvalid("../gst/audiomixer/gstliveadder.c", o, id, spec, 114);
    const ps = latencySpec();
    const owner: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_peek(ps.*.owner_type)));
    var x = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&x, c.G_TYPE_UINT64);
    owner.get_property.?(o, ps.*.param_id, &x, ps);
    c.g_value_set_uint(v, @truncate(c.g_value_get_uint64(&x) / @as(u64, c.GST_MSECOND)));
}

fn liveClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    live_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = liveSetProperty;
    oc.get_property = liveGetProperty;
    c.g_object_class_install_property(oc, LIVEADDER_PROP_LATENCY, c.g_param_spec_uint("latency", "Buffer latency", "Additional latency in live mode to allow upstream to take longer to produce buffers for the current position (in milliseconds)", 0, std.math.maxInt(c.guint), 30, cm.RW | c.G_PARAM_CONSTRUCT));
}

pub fn liveType() c.GType {
    return live_once.get(struct {
        fn f() c.GType {
            return cm.register(getType(), "GstLiveAdder", Class, Self, liveClassInit, init);
        }
    }.f);
}

pub fn registerLive(p: ?*c.GstPlugin) bool {
    elementInit();
    return c.gst_element_register(p, "liveadder", c.GST_RANK_NONE, liveType()) != 0;
}
