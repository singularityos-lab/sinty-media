const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/volume/gstvolume.c";
const CAPS = "audio/x-raw, format = (string) { F32LE, F64LE, S8, S16LE, S24LE, S32LE }, rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) interleaved, layout = (string) interleaved";

const PROP_MUTE = 1;
const PROP_VOLUME = 2;
const PROP_VOLUME_FULL_RANGE = 3;

const UNITY8: i64 = 8;
const UNITY16: i64 = 2048;
const UNITY24: i64 = 524288;
const UNITY32: i64 = 134217728;
const MAX24: i64 = 8388607;
const MIN24: i64 = -8388608;
const MAX32: i64 = std.math.maxInt(i32);

const Process = *const fn (*Self, [*]u8, usize) void;
const Controlled = *const fn (*Self, [*]u8, [*]f64, usize, usize) void;

const Self = extern struct {
    parent: c.GstAudioFilter,
    process: ?Process,
    controlled: ?Controlled,
    mute: c.gboolean,
    volume: f32,
    cur_mute: c.gboolean,
    cur: f64,
    v32: i64,
    v24: i64,
    v16: i64,
    v8: i64,
    negotiated: c.gboolean,
    mutes: ?[*]c.gboolean,
    n_mutes: c.guint,
    volumes: ?[*]f64,
    n_volumes: c.guint,
};

const Class = extern struct {
    parent: c.GstAudioFilterClass,
};

var once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn trans(p: anytype) [*c]c.GstBaseTransform {
    return @ptrCast(@alignCast(p));
}

fn ftz32(x: f32) f32 {
    const b: u32 = @bitCast(x);
    return if (b & 0x7f800000 == 0) @bitCast(b & 0x80000000) else x;
}

fn ftz64(x: f64) f64 {
    const b: u64 = @bitCast(x);
    return if (b & 0x7ff0000000000000 == 0) @bitCast(b & 0x8000000000000000) else x;
}

fn toI32(x: anytype) i32 {
    const T = @TypeOf(x);
    if (std.math.isNan(x) or x >= @as(T, 2147483648.0) or x < @as(T, -2147483648.0)) return if (std.math.signbit(x)) std.math.minInt(i32) else std.math.maxInt(i32);
    return @intFromFloat(x);
}

fn sat(comptime T: type, x: anytype) T {
    return @intCast(std.math.clamp(x, std.math.minInt(T), std.math.maxInt(T)));
}

fn clampF(comptime T: type, x: anytype) T {
    const lo: @TypeOf(x) = @floatFromInt(std.math.minInt(T));
    const hi: @TypeOf(x) = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(std.math.clamp(x, lo, hi));
}

fn samples(comptime T: type, bytes: [*]u8, n: usize) []align(1) T {
    return @as([*]align(1) T, @ptrCast(bytes))[0 .. n / @sizeOf(T)];
}

fn f64Plain(s: *Self, b: [*]u8, n: usize) void {
    for (samples(f64, b, n)) |*d| d.* = ftz64(ftz64(d.*) * ftz64(s.cur));
}

fn f32Plain(s: *Self, b: [*]u8, n: usize) void {
    const v = ftz32(@floatCast(s.cur));
    for (samples(f32, b, n)) |*d| d.* = ftz32(ftz32(d.*) * v);
}

fn shifted(comptime T: type, comptime W: type, comptime shift: u6, comptime clamp: bool) Process {
    return struct {
        fn f(s: *Self, b: [*]u8, n: usize) void {
            const raw = switch (T) {
                i8 => s.v8,
                i16 => s.v16,
                else => s.v32,
            };
            const v: W = @as(T, @truncate(raw));
            for (samples(T, b, n)) |*d| {
                const t = (@as(W, d.*) * v) >> shift;
                d.* = if (clamp) sat(T, t) else @truncate(t);
            }
        }
    }.f;
}

fn viaFloat(comptime T: type, comptime F: type) Process {
    return struct {
        fn f(s: *Self, b: [*]u8, n: usize) void {
            const v: F = @floatCast(s.cur);
            for (samples(T, b, n)) |*d| {
                const x: F = @floatFromInt(d.*);
                d.* = clampF(T, x * v);
            }
        }
    }.f;
}

fn get24(p: [*]u8) i32 {
    return @as(i32, p[0]) | (@as(i32, p[1]) << 8) | (@as(i32, @as(i8, @bitCast(p[2]))) << 16);
}

fn put24(p: [*]u8, v: u32) void {
    p[0] = @truncate(v);
    p[1] = @truncate(v >> 8);
    p[2] = @truncate(v >> 16);
}

fn i24Shift(comptime clamp: bool) Process {
    return struct {
        fn f(s: *Self, b: [*]u8, n: usize) void {
            var i: usize = 0;
            while (i < n / 3) : (i += 1) {
                const p = b + i * 3;
                var val = (s.v24 * @as(i64, get24(p))) >> 19;
                if (clamp) val = std.math.clamp(val, MIN24, MAX24);
                put24(p, @truncate(@as(u64, @bitCast(val))));
            }
        }
    }.f;
}

fn i24Float(s: *Self, b: [*]u8, n: usize) void {
    const v: f32 = @floatCast(s.cur);
    var i: usize = 0;
    while (i < n / 3) : (i += 1) {
        const p = b + i * 3;
        const x = @as(f32, @floatFromInt(get24(p))) * v;
        const r: i32 = @intFromFloat(std.math.clamp(x, @as(f32, @floatFromInt(MIN24)), @as(f32, @floatFromInt(MAX24))));
        put24(p, @bitCast(r));
    }
}

fn ctlF64(_: *Self, b: [*]u8, vol: [*]f64, ch: usize, n: usize) void {
    const d = samples(f64, b, n);
    if (ch == 1) {
        for (d, 0..) |*x, i| x.* = ftz64(ftz64(x.*) * ftz64(vol[i]));
        return;
    }
    for (d, 0..) |*x, i| x.* *= vol[i / ch];
}

fn ctlF32(_: *Self, b: [*]u8, vol: [*]f64, ch: usize, n: usize) void {
    const d = samples(f32, b, n);
    if (ch <= 2) {
        for (d, 0..) |*x, i| x.* = ftz32(ftz32(x.*) * ftz32(@floatCast(ftz64(vol[i / ch]))));
        return;
    }
    for (d, 0..) |*x, i| x.* = @floatCast(@as(f64, x.*) * vol[i / ch]);
}

fn ctlI32(_: *Self, b: [*]u8, vol: [*]f64, ch: usize, n: usize) void {
    const d = samples(i32, b, n);
    if (ch == 1) {
        for (d, 0..) |*x, i| x.* = toI32(ftz64(ftz64(@as(f64, @floatFromInt(x.*))) * ftz64(vol[i])));
        return;
    }
    for (d, 0..) |*x, i| x.* = clampF(i32, @as(f64, @floatFromInt(x.*)) * vol[i / ch]);
}

fn orcSmall(comptime T: type, x: T, v: f64) T {
    const f = ftz32(ftz32(@floatFromInt(x)) * ftz32(@floatCast(ftz64(v))));
    const l = toI32(f);
    if (T == i8) return sat(i8, @as(i16, @truncate(l)));
    return sat(T, l);
}

fn ctlSmall(comptime T: type) Controlled {
    return struct {
        fn f(_: *Self, b: [*]u8, vol: [*]f64, ch: usize, n: usize) void {
            const d = samples(T, b, n);
            if (ch <= 2) {
                for (d, 0..) |*x, i| x.* = orcSmall(T, x.*, vol[i / ch]);
                return;
            }
            for (d, 0..) |*x, i| x.* = clampF(T, @as(f64, @floatFromInt(x.*)) * vol[i / ch]);
        }
    }.f;
}

fn ctlI24(_: *Self, b: [*]u8, vol: [*]f64, ch: usize, n: usize) void {
    var i: usize = 0;
    while (i < n / 3) : (i += 1) {
        const p = b + i * 3;
        const x = std.math.clamp(@as(f64, @floatFromInt(get24(p))) * vol[i / ch], @as(f64, @floatFromInt(MIN24)), @as(f64, @floatFromInt(MAX24)));
        put24(p, @bitCast(@as(i32, @intFromFloat(x))));
    }
}

fn pick(lvl: i64, unity: i64, max: i64, plain: Process, clamp: Process, wide: Process) Process {
    if (lvl <= unity) return plain;
    return if (lvl > max) wide else clamp;
}

fn chooseFunc(s: *Self, info: *const c.GstAudioInfo) bool {
    s.process = null;
    s.controlled = null;
    if (info.finfo == null) return false;
    switch (info.finfo[0].format) {
        c.GST_AUDIO_FORMAT_S32LE => {
            s.process = pick(s.v32, UNITY32, MAX32, shifted(i32, i64, 27, false), shifted(i32, i64, 27, true), viaFloat(i32, f64));
            s.controlled = ctlI32;
        },
        c.GST_AUDIO_FORMAT_S24LE => {
            s.process = pick(s.v24, UNITY24, MAX24, i24Shift(false), i24Shift(true), i24Float);
            s.controlled = ctlI24;
        },
        c.GST_AUDIO_FORMAT_S16LE => {
            s.process = pick(s.v16, UNITY16, std.math.maxInt(i16), shifted(i16, i32, 11, false), shifted(i16, i32, 11, true), viaFloat(i16, f32));
            s.controlled = ctlSmall(i16);
        },
        c.GST_AUDIO_FORMAT_S8 => {
            s.process = pick(s.v8, UNITY8, std.math.maxInt(i8), shifted(i8, i16, 3, false), shifted(i8, i16, 3, true), viaFloat(i8, f32));
            s.controlled = ctlSmall(i8);
        },
        c.GST_AUDIO_FORMAT_F32LE => {
            s.process = f32Plain;
            s.controlled = ctlF32;
        },
        c.GST_AUDIO_FORMAT_F64LE => {
            s.process = f64Plain;
            s.controlled = ctlF64;
        },
        else => {},
    }
    return s.process != null;
}

fn level(v: f64, unity: i64) i64 {
    return @intFromFloat(std.math.clamp(v * @as(f64, @floatFromInt(unity)), 0, 2.0 * @as(f64, @floatFromInt(MAX32))));
}

fn update(s: *Self, info: *const c.GstAudioInfo, vol: f64, mute: bool) bool {
    var pass = false;
    if (mute) {
        s.cur_mute = 1;
        s.cur = 0;
        s.v8 = 0;
        s.v16 = 0;
        s.v24 = 0;
        s.v32 = 0;
    } else {
        s.cur_mute = 0;
        s.cur = vol;
        s.v8 = level(vol, UNITY8);
        s.v16 = level(vol, UNITY16);
        s.v24 = level(vol, UNITY24);
        s.v32 = level(vol, UNITY32);
        if (info.finfo != null) pass = switch (info.finfo[0].format) {
            c.GST_AUDIO_FORMAT_F32LE, c.GST_AUDIO_FORMAT_F64LE => s.cur == 1.0,
            c.GST_AUDIO_FORMAT_S8 => s.v8 == UNITY8,
            c.GST_AUDIO_FORMAT_S16LE => s.v16 == UNITY16,
            c.GST_AUDIO_FORMAT_S24LE => s.v24 == UNITY24,
            c.GST_AUDIO_FORMAT_S32LE => s.v32 == UNITY32,
            else => false,
        };
    }
    pass = pass and c.gst_object_has_active_control_bindings(cm.obj(s)) == 0;
    c.gst_base_transform_set_passthrough(trans(s), @intFromBool(pass));
    const ok = chooseFunc(s, info);
    s.negotiated = @intFromBool(ok);
    return ok;
}

fn setup(f: [*c]c.GstAudioFilter, info: [*c]const c.GstAudioInfo) callconv(.c) c.gboolean {
    const s = me(f);
    cm.lock(s);
    const vol: f64 = s.volume;
    const mute = s.mute != 0;
    cm.unlock(s);
    const ok = update(s, info, vol, mute);
    if (!ok) cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, c.g_strdup("Invalid incoming format"), null, FILE, "volume_setup", 821);
    s.negotiated = @intFromBool(ok);
    return @intFromBool(ok);
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    const s = me(bt);
    c.g_free(@ptrCast(s.volumes));
    s.volumes = null;
    s.n_volumes = 0;
    c.g_free(@ptrCast(s.mutes));
    s.mutes = null;
    s.n_mutes = 0;
    if (parent.?.stop) |f| return f(bt);
    return 1;
}

fn streamTime(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) u64 {
    return c.gst_segment_to_stream_time(&bt[0].segment, c.GST_FORMAT_TIME, b[0].pts);
}

fn beforeTransform(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) void {
    const s = me(bt);
    const ts = streamTime(bt, b);
    if (ts != cm.CLOCK_NONE) _ = c.gst_object_sync_values(cm.obj(s), ts);
    cm.lock(s);
    const vol: f64 = s.volume;
    const mute = s.mute;
    cm.unlock(s);
    if (vol != s.cur or mute != s.cur_mute) _ = update(s, &s.parent.info, vol, mute != 0);
}

fn controlled(s: *Self, bt: [*c]c.GstBaseTransform, ts: u64, data: [*]u8, size: usize) bool {
    var mute_cb = c.gst_object_get_control_binding(cm.obj(s), "mute");
    var vol_cb = c.gst_object_get_control_binding(cm.obj(s), "volume");
    if (!(mute_cb != null or (vol_cb != null and s.cur_mute == 0))) {
        if (vol_cb != null) c.gst_object_unref(vol_cb);
        return false;
    }
    const info = &s.parent.info;
    const width: usize = @intCast(@divTrunc(info.finfo[0].width, 8));
    const ch: usize = @intCast(info.channels);
    const n: c.guint = @intCast(size / (width * ch));
    const interval = c.gst_util_uint64_scale_int(1, c.GST_SECOND, info.rate);
    var have_mutes = false;
    var have_vols = false;
    if (s.n_mutes < n and mute_cb != null) {
        s.mutes = @ptrCast(@alignCast(c.g_realloc(@ptrCast(s.mutes), @sizeOf(c.gboolean) * n)));
        s.n_mutes = n;
    }
    if (s.n_volumes < n) {
        s.volumes = @ptrCast(@alignCast(c.g_realloc(@ptrCast(s.volumes), @sizeOf(f64) * n)));
        s.n_volumes = n;
    }
    if (vol_cb != null and s.volumes != null) {
        have_vols = c.gst_control_binding_get_value_array(vol_cb, ts, interval, n, @ptrCast(s.volumes)) != 0;
        _ = c.gst_object_replace(@ptrCast(&vol_cb), null);
    }
    if (!have_vols) {
        for (s.volumes.?[0..n]) |*v| v.* = s.cur;
    }
    if (mute_cb != null and s.mutes != null) {
        have_mutes = c.gst_control_binding_get_value_array(mute_cb, ts, interval, n, @ptrCast(s.mutes)) != 0;
        _ = c.gst_object_replace(@ptrCast(&mute_cb), null);
    }
    if (have_mutes) {
        for (s.volumes.?[0..n], s.mutes.?[0..n]) |*v, m| v.* = ftz64(ftz64(v.*) * ftz64(1.0 - @as(f64, @floatFromInt(m))));
    } else {
        c.g_free(@ptrCast(s.mutes));
        s.mutes = null;
        s.n_mutes = 0;
    }
    _ = bt;
    s.controlled.?(s, data, s.volumes.?, ch, size);
    return true;
}

fn transformIp(bt: [*c]c.GstBaseTransform, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    if (s.negotiated == 0) {
        cm.elementError(s, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, c.g_strdup("No format was negotiated"), null, FILE, "volume_transform_ip", 972);
        return c.GST_FLOW_NOT_NEGOTIATED;
    }
    if (b[0].mini_object.flags & c.GST_BUFFER_FLAG_GAP != 0) return c.GST_FLOW_OK;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READWRITE);
    defer c.gst_buffer_unmap(b, &map);
    const data: [*]u8 = @ptrCast(map.data);
    const ts = streamTime(bt, b);
    if (ts != cm.CLOCK_NONE and controlled(s, bt, ts, data, map.size)) return c.GST_FLOW_OK;
    if (s.cur == 0.0 or s.cur_mute != 0) {
        @memset(data[0..map.size], 0);
        b[0].mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
    } else if (s.cur != 1.0) s.process.?(s, data, map.size);
    return c.GST_FLOW_OK;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_MUTE => {
            cm.lock(s);
            s.mute = c.g_value_get_boolean(v);
            cm.unlock(s);
        },
        PROP_VOLUME, PROP_VOLUME_FULL_RANGE => {
            cm.lock(s);
            s.volume = @floatCast(c.g_value_get_double(v));
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1001),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_MUTE => {
            cm.lock(s);
            c.g_value_set_boolean(v, s.mute);
            cm.unlock(s);
        },
        PROP_VOLUME => {
            cm.lock(s);
            c.g_value_set_double(v, if (s.volume > 10.0) 10.0 else s.volume);
            cm.unlock(s);
        },
        PROP_VOLUME_FULL_RANGE => {
            cm.lock(s);
            c.g_value_set_double(v, s.volume);
            cm.unlock(s);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1035),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const F = cm.RW | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_MUTE, c.g_param_spec_boolean("mute", "Mute", "mute channel", 0, F));
    c.g_object_class_install_property(oc, PROP_VOLUME_FULL_RANGE, c.g_param_spec_double("volume-full-range", "Volume", "volume factor with a full range of values, 1.0=100%", 0.0, std.math.floatMax(f64), 1.0, F));
    c.g_object_class_install_property(oc, PROP_VOLUME, c.g_param_spec_double("volume", "Volume", "volume factor, 1.0=100%", 0.0, 10.0, 1.0, F));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Volume", "Filter/Effect/Audio", "Set volume on audio/raw streams", "Andy Wingo <wingo@pobox.com>");
    const caps = c.gst_caps_from_string(CAPS);
    c.gst_audio_filter_class_add_pad_templates(@ptrCast(@alignCast(k)), caps);
    c.gst_mini_object_unref(@ptrCast(caps));
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.before_transform = beforeTransform;
    tc.transform_ip = transformIp;
    tc.stop = stop;
    tc.transform_ip_on_passthrough = 0;
    const fc: *c.GstAudioFilterClass = @ptrCast(@alignCast(k));
    fc.setup = setup;
    _ = c._gst_debug_category_new("volume", 0, "Volume gain");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.mute = 0;
    s.volume = 1.0;
    s.negotiated = 0;
    c.gst_base_transform_set_gap_aware(trans(s), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_audio_filter_get_type(), "GstVolume", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = null, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_stream_volume_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "volume", c.GST_RANK_NONE, getType()) != 0;
}
