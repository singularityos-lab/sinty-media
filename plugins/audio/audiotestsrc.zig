const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const libm = @import("../libm.zig");
const sin = libm.sin;
const cos = libm.cos;
const log = libm.log;
const sqrt = libm.sqrt;

const FILE = "../gst/audiotestsrc/gstaudiotestsrc.c";
const FORMATS = " { S16LE, S16BE, U16LE, U16BE, S24_32LE, S24_32BE, U24_32LE, U24_32BE, S32LE, S32BE, U32LE, U32BE, S24LE, S24BE, U24LE, U24BE, S20LE, S20BE, U20LE, U20BE, S18LE, S18BE, U18LE, U18BE, F32LE, F32BE, F64LE, F64BE, S8, U8 }";
const CAPS = "audio/x-raw, format = (string) " ++ FORMATS ++ ", layout = (string) { interleaved, non-interleaved }, rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE;
const TAU = std.math.pi + std.math.pi;
const PI = std.math.pi;
const HALF_PI = std.math.pi / 2.0;
const SEC: u64 = 1_000_000_000;

const PROP_SAMPLES_PER_BUFFER = 1;
const PROP_WAVE = 2;
const PROP_FREQ = 3;
const PROP_VOLUME = 4;
const PROP_IS_LIVE = 5;
const PROP_TIMESTAMP_OFFSET = 6;
const PROP_SINE_PERIODS_PER_TICK = 7;
const PROP_TICK_INTERVAL = 8;
const PROP_MARKER_TICK_PERIOD = 9;
const PROP_MARKER_TICK_VOLUME = 10;
const PROP_APPLY_TICK_RAMP = 11;
const PROP_CAN_ACTIVATE_PUSH = 12;
const PROP_CAN_ACTIVATE_PULL = 13;

const Wave = enum(c.gint) { sine, square, saw, triangle, silence, white, pink, sine_tab, ticks, gaussian, red, blue, violet };

const Self = extern struct {
    parent: c.GstBaseSrc,
    ready: c.gboolean,
    idx: c.gint,
    pack: c.GstAudioFormatPack,
    pack_size: c.gint,
    tmp: ?*anyopaque,
    tmpsize: usize,
    wave: c.gint,
    volume: f64,
    freq: f64,
    info: c.GstAudioInfo,
    samples_per_buffer: c.gint,
    tags_pushed: c.gboolean,
    timestamp_offset: i64,
    next_time: u64,
    next_sample: i64,
    next_byte: i64,
    sample_stop: i64,
    check_seek_stop: c.gboolean,
    eos_reached: c.gboolean,
    gen_samples: c.gint,
    can_activate_pull: c.gboolean,
    reverse: c.gboolean,
    gen: ?*c.GRand,
    acc: f64,
    pink_rows: [30]c.glong,
    pink_sum: c.glong,
    pink_index: c.gint,
    pink_mask: c.gint,
    pink_scalar: f64,
    red_state: f64,
    table: [1024]f64,
    periods_per_tick: c.guint,
    tick_interval: u64,
    marker_period: c.guint,
    marker_volume: f64,
    tick_ramp: c.gboolean,
    between_ticks: c.guint,
    tick_counter: c.guint,
};

const Class = extern struct {
    parent: c.GstBaseSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var wave_once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;
var blue_flip = [4]f64{ 1.0, 1.0, 1.0, 1.0 };
var violet_flip = [4]f64{ 1.0, 1.0, 1.0, 1.0 };

var waves = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "Sine", .value_nick = "sine" },
    .{ .value = 1, .value_name = "Square", .value_nick = "square" },
    .{ .value = 2, .value_name = "Saw", .value_nick = "saw" },
    .{ .value = 3, .value_name = "Triangle", .value_nick = "triangle" },
    .{ .value = 4, .value_name = "Silence", .value_nick = "silence" },
    .{ .value = 5, .value_name = "White uniform noise", .value_nick = "white-noise" },
    .{ .value = 6, .value_name = "Pink noise", .value_nick = "pink-noise" },
    .{ .value = 7, .value_name = "Sine table", .value_nick = "sine-table" },
    .{ .value = 8, .value_name = "Periodic Ticks", .value_nick = "ticks" },
    .{ .value = 9, .value_name = "White Gaussian noise", .value_nick = "gaussian-noise" },
    .{ .value = 10, .value_name = "Red (brownian) noise", .value_nick = "red-noise" },
    .{ .value = 11, .value_name = "Blue noise", .value_nick = "blue-noise" },
    .{ .value = 12, .value_name = "Violet noise", .value_nick = "violet-noise" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn waveType() c.GType {
    return wave_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstAudioTestSrcWave", &waves);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn base(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn cast(comptime T: type, x: f64) T {
    if (@typeInfo(T) == .float) return @floatCast(x);
    const w: i32 = if (x > -2147483649.0 and x < 2147483648.0) @intFromFloat(x) else std.math.minInt(i32);
    return @truncate(w);
}

fn wide(x: anytype) f64 {
    return if (@typeInfo(@TypeOf(x)) == .float) x else @floatFromInt(x);
}

fn scaleOf(comptime T: type) f64 {
    return switch (T) {
        i16 => 32767.0,
        i32 => 2147483647.0,
        else => 1.0,
    };
}

const Steps = struct { ch: usize, cs: usize, ss: usize, n: usize };

fn steps(s: *Self) Steps {
    const ch: usize = @intCast(s.info.channels);
    const n: usize = @intCast(s.gen_samples);
    if (s.info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) return .{ .ch = ch, .cs = 1, .ss = ch, .n = n };
    return .{ .ch = ch, .cs = n, .ss = 1, .n = n };
}

fn advance(s: *Self, step: f64) void {
    s.acc += step;
    if (s.acc >= TAU) s.acc -= TAU;
}

fn fillAll(comptime T: type, out: [*]T, st: Steps, i: usize, v: T) void {
    var k: usize = 0;
    while (k < st.ch) : (k += 1) out[i * st.ss + k * st.cs] = v;
}

fn oscillator(comptime T: type, s: *Self, out: [*]T, w: Wave) void {
    const st = steps(s);
    const step = TAU * s.freq / @as(f64, @floatFromInt(s.info.rate));
    const amp = switch (w) {
        .saw => (s.volume * scaleOf(T)) / PI,
        .triangle => (s.volume * scaleOf(T)) / HALF_PI,
        else => s.volume * scaleOf(T),
    };
    const scl = 1024.0 / TAU;
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        advance(s, step);
        const a = s.acc;
        const v: T = switch (w) {
            .sine => cast(T, sin(a) * amp),
            .square => cast(T, if (a < PI) amp else -amp),
            .saw => cast(T, if (a < PI) a * amp else (TAU - a) * -amp),
            .triangle => cast(T, if (a < HALF_PI) a * amp else if (a < PI * 1.5) (a - PI) * -amp else (TAU - a) * -amp),
            else => cast(T, wide(cast(T, scaleOf(T))) * s.table[tableIndex(a * scl)]),
        };
        fillAll(T, out, st, i, v);
    }
}

fn tableIndex(x: f64) usize {
    return @min(@as(usize, @intCast(@as(i32, @intFromFloat(x)))), 1023);
}

fn white(comptime T: type, s: *Self, out: [*]T) void {
    const st = steps(s);
    const amp = s.volume * scaleOf(T);
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        var k: usize = 0;
        while (k < st.ch) : (k += 1) out[i * st.ss + k * st.cs] = cast(T, amp * c.g_rand_double_range(s.gen, -1.0, 1.0));
    }
}

fn pinkInit(s: *Self) void {
    const rows = 12;
    s.pink_index = 0;
    s.pink_mask = (1 << rows) - 1;
    const pmax: c.glong = (rows + 1) * (1 << 15);
    s.pink_scalar = @as(f32, 1.0) / @as(f32, @floatFromInt(pmax));
    for (s.pink_rows[0..rows]) |*r| r.* = 0;
    s.pink_sum = 0;
}

fn pinkRandom(s: *Self) c.glong {
    const r: f64 = @floatFromInt(c.g_rand_int(s.gen));
    return @intFromFloat(32768.0 - (65536.0 * r / (4294967295.0 + 1.0)));
}

fn pinkValue(s: *Self) f64 {
    s.pink_index = (s.pink_index + 1) & s.pink_mask;
    if (s.pink_index != 0) {
        const zeros: usize = @ctz(@as(c.guint, @bitCast(s.pink_index)));
        s.pink_sum -= s.pink_rows[zeros];
        const nr = pinkRandom(s);
        s.pink_sum += nr;
        s.pink_rows[zeros] = nr;
    }
    const sum = s.pink_sum + pinkRandom(s);
    return s.pink_scalar * @as(f64, @floatFromInt(sum));
}

fn pink(comptime T: type, s: *Self, out: [*]T) void {
    const st = steps(s);
    const amp = s.volume * scaleOf(T);
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        var k: usize = 0;
        while (k < st.ch) : (k += 1) out[i * st.ss + k * st.cs] = cast(T, pinkValue(s) * amp);
    }
}

fn gaussian(comptime T: type, s: *Self, out: [*]T) void {
    const st = steps(s);
    const amp = s.volume * scaleOf(T);
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        var k: usize = 0;
        while (k < st.ch) : (k += 1) {
            const mag = sqrt(-2 * log(1.0 - c.g_rand_double(s.gen)));
            const phs = c.g_rand_double_range(s.gen, 0.0, TAU);
            out[i * st.ss + k * st.cs] = cast(T, amp * mag * cos(phs));
            k += 1;
            if (k >= st.ch) break;
            out[i * st.ss + k * st.cs] = cast(T, amp * mag * sin(phs));
        }
    }
}

fn red(comptime T: type, s: *Self, out: [*]T) void {
    const st = steps(s);
    const amp = s.volume * scaleOf(T);
    var state = s.red_state;
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        var k: usize = 0;
        while (k < st.ch) : (k += 1) {
            while (true) {
                const r = c.g_rand_double_range(s.gen, -1.0, 1.0);
                state += r;
                if (state < -8.0 or state > 8.0) state -= r else break;
            }
            out[i * st.ss + k * st.cs] = cast(T, amp * state * 0.0625);
        }
    }
    s.red_state = state;
}

fn flipped(comptime T: type, s: *Self, out: [*]T, flip: *f64) void {
    const st = steps(s);
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        var k: usize = 0;
        while (k < st.ch) : (k += 1) {
            const p = &out[i * st.ss + k * st.cs];
            p.* = cast(T, wide(p.*) * flip.*);
        }
        flip.* *= -1.0;
    }
}

fn tickVolume(s: *Self, scale: f64) f64 {
    const vol = if (s.marker_period > 0 and s.tick_counter % s.marker_period == 0) s.marker_volume else s.volume;
    return vol * scale;
}

fn ticks(comptime T: type, s: *Self, out: [*]T) void {
    const st = steps(s);
    var volscale = tickVolume(s, scaleOf(T));
    const rate = s.info.rate;
    const step = TAU * s.freq / @as(f64, @floatFromInt(rate));
    const prod: c.guint = @as(c.guint, @bitCast(rate)) *% s.periods_per_tick;
    const nonzero: i32 = cast(i32, @as(f64, @floatFromInt(prod)) / s.freq);
    const scl = 1024.0 / TAU;
    const ramp_n: i32 = if (s.tick_ramp != 0) cast(i32, @as(f64, @floatFromInt(rate)) / s.freq) else 0;
    const end_ramp = nonzero - ramp_n;
    var i: usize = 0;
    while (i < st.n) : (i += 1) {
        const mod: i32 = @truncate(@rem(s.next_sample + @as(i64, @intCast(i)), @as(i64, s.between_ticks)));
        if (mod == 0) {
            s.acc = 0;
            s.tick_counter +%= 1;
            volscale = tickVolume(s, scaleOf(T));
            fillAll(T, out, st, i, 0);
        } else if (mod < nonzero) {
            var ramp: f64 = 1.0;
            if (ramp_n > 0) {
                const n: f64 = @floatFromInt(ramp_n);
                ramp = if (mod < ramp_n) @as(f64, @floatFromInt(mod)) / n else if (mod >= end_ramp) @as(f64, @floatFromInt(nonzero - mod)) / n else 1.0;
                if (ramp > 1.0) ramp = 1.0;
                ramp *= ramp * ramp;
            }
            fillAll(T, out, st, i, cast(T, wide(cast(T, volscale)) * ramp * s.table[tableIndex(s.acc * scl)]));
        } else fillAll(T, out, st, i, 0);
        advance(s, step);
    }
}

fn generate(comptime T: type, s: *Self, out: [*]T, slot: usize) void {
    switch (@as(Wave, @enumFromInt(s.wave))) {
        .sine => oscillator(T, s, out, .sine),
        .square => oscillator(T, s, out, .square),
        .saw => oscillator(T, s, out, .saw),
        .triangle => oscillator(T, s, out, .triangle),
        .sine_tab => oscillator(T, s, out, .sine_tab),
        .silence => @memset(out[0 .. @as(usize, @intCast(s.gen_samples)) * @as(usize, @intCast(s.info.channels))], 0),
        .white => white(T, s, out),
        .pink => pink(T, s, out),
        .ticks => ticks(T, s, out),
        .gaussian => gaussian(T, s, out),
        .red => red(T, s, out),
        .blue => {
            pink(T, s, out);
            flipped(T, s, out, &blue_flip[slot]);
        },
        .violet => {
            red(T, s, out);
            flipped(T, s, out, &violet_flip[slot]);
        },
    }
}

fn process(s: *Self, data: *anyopaque) void {
    switch (s.idx) {
        0 => generate(i16, s, @ptrCast(@alignCast(data)), 0),
        1 => generate(i32, s, @ptrCast(@alignCast(data)), 1),
        2 => generate(f32, s, @ptrCast(@alignCast(data)), 2),
        else => generate(f64, s, @ptrCast(@alignCast(data)), 3),
    }
}

fn sineTable(s: *Self, use_volume: bool) void {
    var ang: f64 = 0.0;
    const step = TAU / 1024.0;
    const amp = if (use_volume) s.volume else 1.0;
    for (&s.table) |*t| {
        t.* = sin(ang) * amp;
        ang += step;
    }
}

fn needRand(s: *Self) void {
    if (s.gen == null) s.gen = c.g_rand_new();
}

fn changeWave(s: *Self) void {
    s.pack = null;
    s.ready = 0;
    if (s.info.finfo == null) return;
    s.idx = switch (s.info.finfo[0].format) {
        c.GST_AUDIO_FORMAT_S16LE => 0,
        c.GST_AUDIO_FORMAT_S32LE => 1,
        c.GST_AUDIO_FORMAT_F32LE => 2,
        c.GST_AUDIO_FORMAT_F64LE => 3,
        else => blk: {
            s.pack = s.info.finfo[0].pack_func;
            if (s.info.finfo[0].unpack_format == c.GST_AUDIO_FORMAT_S32LE) {
                s.pack_size = 4;
                break :blk 1;
            }
            if (s.info.finfo[0].unpack_format == c.GST_AUDIO_FORMAT_F64LE) {
                s.pack_size = 8;
                break :blk 3;
            }
            c.g_assertion_message_expr(null, FILE, 1242, "gst_audio_test_src_change_wave", null);
            return;
        },
    };
    switch (@as(Wave, @enumFromInt(s.wave))) {
        .white, .gaussian => needRand(s),
        .pink, .blue => {
            needRand(s);
            pinkInit(s);
        },
        .red, .violet => {
            needRand(s);
            s.red_state = 0.0;
        },
        .sine_tab => sineTable(s, true),
        .ticks => {
            sineTable(s, false);
            s.between_ticks = @truncate(c.gst_util_uint64_scale_int(s.tick_interval, s.info.rate, @intCast(SEC)));
        },
        else => {},
    }
    s.ready = 1;
}

fn fixate(bs: [*c]c.GstBaseSrc, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    const caps: [*c]c.GstCaps = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(caps_in))));
    const st = c.gst_caps_get_structure(caps, 0);
    const rate: c.gint = cast(i32, @max(@as(f64, c.GST_AUDIO_DEF_RATE), s.freq * 2));
    _ = c.gst_structure_fixate_field_nearest_int(st, "rate", rate);
    _ = c.gst_structure_fixate_field_string(st, "format", "\"S16\"LE");
    _ = c.gst_structure_fixate_field_string(st, "layout", "interleaved");
    _ = c.gst_structure_fixate_field_nearest_int(st, "channels", 1);
    var channels: c.gint = 0;
    if (c.gst_structure_get_int(st, "channels", &channels) != 0 and channels > 2) {
        if (c.gst_structure_has_field_typed(st, "channel-mask", c.gst_bitmask_get_type()) == 0) {
            c.gst_structure_set(st, "channel-mask", c.gst_bitmask_get_type(), c.gst_audio_channel_get_fallback_mask(channels), @as(?*anyopaque, null));
        }
    }
    return parent.?.fixate.?(bs, caps);
}

fn setCaps(bs: [*c]c.GstBaseSrc, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return 0;
    s.info = info;
    c.gst_base_src_set_blocksize(bs, @bitCast(info.bpf *% s.samples_per_buffer));
    changeWave(s);
    return 1;
}

fn query(bs: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            if (c.gst_audio_info_convert(&s.info, sf, sv, df, &dv) == 0) return 0;
            c.gst_query_set_convert(q, sf, sv, df, dv);
            return 1;
        },
        c.GST_QUERY_SCHEDULING => {
            c.gst_query_set_scheduling(q, c.GST_SCHEDULING_FLAG_SEEKABLE, 1, -1, 0);
            c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PUSH);
            if (s.can_activate_pull != 0) c.gst_query_add_scheduling_mode(q, c.GST_PAD_MODE_PULL);
            return 1;
        },
        c.GST_QUERY_LATENCY => {
            if (s.info.rate <= 0) return 0;
            const lat = c.gst_util_uint64_scale(@bitCast(@as(i64, s.gen_samples)), SEC, @intCast(s.info.rate));
            c.gst_query_set_latency(q, c.gst_base_src_is_live(bs), lat, cm.CLOCK_NONE);
            return 1;
        },
        else => return parent.?.query.?(bs, q),
    }
}

fn getTimes(bs: [*c]c.GstBaseSrc, b: [*c]c.GstBuffer, first: [*c]c.GstClockTime, last: [*c]c.GstClockTime) callconv(.c) void {
    if (c.gst_base_src_is_live(bs) != 0) {
        const ts = b[0].pts;
        if (ts != cm.CLOCK_NONE) {
            const d = b[0].duration;
            if (d != cm.CLOCK_NONE) last.* = ts +% d;
            first.* = ts;
        }
    } else {
        first.* = cm.CLOCK_NONE;
        last.* = cm.CLOCK_NONE;
    }
}

fn start(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    s.next_sample = 0;
    s.next_byte = 0;
    s.next_time = 0;
    s.check_seek_stop = 0;
    s.eos_reached = 0;
    s.tags_pushed = 0;
    s.acc = 0;
    s.tick_counter = 0;
    return 1;
}

fn stop(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn isSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn doSeek(bs: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const s = me(bs);
    var time = seg[0].position;
    s.reverse = @intFromBool(seg[0].rate < 0.0);
    const rate = s.info.rate;
    const bpf = s.info.bpf;
    const next: i64 = @bitCast(c.gst_util_uint64_scale_int(time, rate, @intCast(SEC)));
    s.next_byte = next *% bpf;
    s.next_time = if (rate == 0) 0 else c.gst_util_uint64_scale_round(@bitCast(next), SEC, @intCast(rate));
    if (!(s.next_time <= time)) c.g_assertion_message_expr(null, FILE, 1407, "gst_audio_test_src_do_seek", "src->next_time <= time");
    s.next_sample = next;
    if (seg[0].rate > 0 and seg[0].stop != cm.CLOCK_NONE) {
        time = seg[0].stop;
        s.sample_stop = @bitCast(c.gst_util_uint64_scale_round(time, @intCast(rate), SEC));
        s.check_seek_stop = 1;
    } else if (seg[0].rate < 0) {
        time = seg[0].start;
        s.sample_stop = @bitCast(c.gst_util_uint64_scale_round(time, @intCast(rate), SEC));
        s.check_seek_stop = 1;
    } else s.check_seek_stop = 0;
    s.eos_reached = 0;
    return 1;
}

fn fill(bs: [*c]c.GstBaseSrc, offset_in: u64, length: c.guint, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bs);
    if (s.tags_pushed == 0) {
        const tags = c.gst_tag_list_new(c.GST_TAG_DESCRIPTION, "audiotest wave", @as(?*anyopaque, null));
        const ec: *c.GstElementClass = @ptrCast(@alignCast(parent.?));
        if (ec.send_event) |f| {
            _ = f(@ptrCast(@alignCast(bs)), c.gst_event_new_tag(tags));
        } else c.gst_mini_object_unref(@ptrCast(tags));
        s.tags_pushed = 1;
    }
    if (s.eos_reached != 0) return c.GST_FLOW_EOS;
    const rate = s.info.rate;
    const bpf = s.info.bpf;
    const samples: i64 = if (length == std.math.maxInt(c.guint)) s.samples_per_buffer else @as(c.guint, @truncate(length / @as(c.guint, @bitCast(bpf))));
    var offset = offset_in;
    if (offset == std.math.maxInt(u64)) offset = @bitCast(s.next_byte);
    if (offset != @as(u64, @bitCast(s.next_byte))) {
        s.next_sample = @bitCast(offset / @as(u64, @intCast(bpf)));
        s.next_time = c.gst_util_uint64_scale_int(@bitCast(s.next_sample), @intCast(SEC), rate);
        s.next_byte = @bitCast(offset);
    }
    var next_sample: i64 = 0;
    if (s.check_seek_stop != 0 and s.reverse == 0 and s.sample_stop > s.next_sample and s.sample_stop < s.next_sample + samples) {
        s.gen_samples = @truncate(s.sample_stop - s.next_sample);
        next_sample = s.sample_stop;
        s.eos_reached = 1;
    } else if (s.check_seek_stop != 0 and s.reverse != 0 and s.sample_stop >= s.next_sample - samples) {
        s.gen_samples = @truncate(s.next_sample - s.sample_stop);
        next_sample = s.sample_stop;
        s.eos_reached = 1;
    } else {
        s.gen_samples = @truncate(samples);
        next_sample = s.next_sample + (if (s.reverse != 0) -samples else samples);
    }
    const bytes: c.gint = s.gen_samples *% bpf;
    const next_byte = s.next_byte + (if (s.reverse != 0) -@as(i64, bytes) else bytes);
    const next_time = c.gst_util_uint64_scale_int(@bitCast(next_sample), @intCast(SEC), rate);
    c.gst_buffer_set_size(b, bytes);
    b[0].offset = @bitCast(s.next_sample);
    b[0].offset_end = @bitCast(next_sample);
    if (s.reverse == 0) {
        b[0].pts = @as(u64, @bitCast(s.timestamp_offset)) +% s.next_time;
        b[0].duration = next_time -% s.next_time;
    } else {
        b[0].pts = @as(u64, @bitCast(s.timestamp_offset)) +% next_time;
        b[0].duration = s.next_time -% next_time;
    }
    _ = c.gst_object_sync_values(cm.obj(s), b[0].pts);
    s.next_time = next_time;
    s.next_sample = next_sample;
    s.next_byte = next_byte;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_WRITE);
    const count = @as(usize, @intCast(s.gen_samples)) * @as(usize, @intCast(s.info.channels));
    if (s.pack) |pack| {
        const size = count * @as(usize, @intCast(s.pack_size));
        if (size > s.tmpsize) {
            s.tmp = c.g_realloc(s.tmp, size);
            s.tmpsize = size;
        }
        process(s, s.tmp.?);
        pack(s.info.finfo, 0, s.tmp, map.data, @intCast(count));
    } else process(s, map.data);
    c.gst_buffer_unmap(b, &map);
    if (s.wave == @intFromEnum(Wave.silence) or s.volume == 0.0) b[0].mini_object.flags |= c.GST_BUFFER_FLAG_GAP;
    if (s.info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) _ = c.gst_buffer_add_audio_meta(b, &s.info, @intCast(s.gen_samples), null);
    return c.GST_FLOW_OK;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SAMPLES_PER_BUFFER => {
            s.samples_per_buffer = c.g_value_get_int(v);
            c.gst_base_src_set_blocksize(base(s), @bitCast(s.info.bpf *% s.samples_per_buffer));
        },
        PROP_WAVE => {
            s.wave = c.g_value_get_enum(v);
            changeWave(s);
        },
        PROP_FREQ => s.freq = c.g_value_get_double(v),
        PROP_VOLUME => {
            s.volume = c.g_value_get_double(v);
            if (s.wave == @intFromEnum(Wave.sine_tab)) sineTable(s, true);
        },
        PROP_IS_LIVE => c.gst_base_src_set_live(base(s), c.g_value_get_boolean(v)),
        PROP_TIMESTAMP_OFFSET => s.timestamp_offset = c.g_value_get_int64(v),
        PROP_SINE_PERIODS_PER_TICK => s.periods_per_tick = c.g_value_get_uint(v),
        PROP_TICK_INTERVAL => s.tick_interval = c.g_value_get_uint64(v),
        PROP_MARKER_TICK_PERIOD => s.marker_period = c.g_value_get_uint(v),
        PROP_MARKER_TICK_VOLUME => s.marker_volume = c.g_value_get_double(v),
        PROP_APPLY_TICK_RAMP => s.tick_ramp = c.g_value_get_boolean(v),
        PROP_CAN_ACTIVATE_PUSH => s.parent.can_activate_push = c.g_value_get_boolean(v),
        PROP_CAN_ACTIVATE_PULL => s.can_activate_pull = c.g_value_get_boolean(v),
        else => cm.warnInvalid(FILE, o, id, spec, 1632),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_SAMPLES_PER_BUFFER => c.g_value_set_int(v, s.samples_per_buffer),
        PROP_WAVE => c.g_value_set_enum(v, s.wave),
        PROP_FREQ => c.g_value_set_double(v, s.freq),
        PROP_VOLUME => c.g_value_set_double(v, s.volume),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(base(s))),
        PROP_TIMESTAMP_OFFSET => c.g_value_set_int64(v, s.timestamp_offset),
        PROP_SINE_PERIODS_PER_TICK => c.g_value_set_uint(v, s.periods_per_tick),
        PROP_TICK_INTERVAL => c.g_value_set_uint64(v, s.tick_interval),
        PROP_MARKER_TICK_PERIOD => c.g_value_set_uint(v, s.marker_period),
        PROP_MARKER_TICK_VOLUME => c.g_value_set_double(v, s.marker_volume),
        PROP_APPLY_TICK_RAMP => c.g_value_set_boolean(v, s.tick_ramp),
        PROP_CAN_ACTIVATE_PUSH => c.g_value_set_boolean(v, s.parent.can_activate_push),
        PROP_CAN_ACTIVATE_PULL => c.g_value_set_boolean(v, s.can_activate_pull),
        else => cm.warnInvalid(FILE, o, id, spec, 1684),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.gen) |g| c.g_rand_free(g);
    s.gen = null;
    c.g_free(s.tmp);
    s.tmp = null;
    s.tmpsize = 0;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const CT = cm.RW | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_SAMPLES_PER_BUFFER, c.g_param_spec_int("samplesperbuffer", "Samples per buffer", "Number of samples in each outgoing buffer", 1, std.math.maxInt(c.gint), 1024, cm.RW));
    c.g_object_class_install_property(oc, PROP_WAVE, c.g_param_spec_enum("wave", "Waveform", "Oscillator waveform", waveType(), 0, CT));
    c.g_object_class_install_property(oc, PROP_FREQ, c.g_param_spec_double("freq", "Frequency", "Frequency of test signal. The sample rate needs to be at least 2 times higher.", 0.0, @as(f64, std.math.maxInt(c.gint)) / 2, 440.0, CT));
    c.g_object_class_install_property(oc, PROP_VOLUME, c.g_param_spec_double("volume", "Volume", "Volume of test signal", 0.0, 1.0, 0.8, CT));
    c.g_object_class_install_property(oc, PROP_IS_LIVE, c.g_param_spec_boolean("is-live", "Is Live", "Whether to act as a live source", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TIMESTAMP_OFFSET, c.g_param_spec_int64("timestamp-offset", "Timestamp offset", "An offset added to timestamps set on buffers (in ns)", std.math.minInt(i64), std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_SINE_PERIODS_PER_TICK, c.g_param_spec_uint("sine-periods-per-tick", "Sine periods per tick", "Number of sine wave periods in one tick. Only used if wave = ticks.", 1, std.math.maxInt(c.guint), 10, cm.RW));
    c.g_object_class_install_property(oc, PROP_TICK_INTERVAL, c.g_param_spec_uint64("tick-interval", "Time between ticks", "Distance between start of current and start of next tick, in nanoseconds.", 1, std.math.maxInt(u64), SEC, cm.RW));
    c.g_object_class_install_property(oc, PROP_MARKER_TICK_PERIOD, c.g_param_spec_uint("marker-tick-period", "Marker tick period", "Make every Nth tick a marker tick (= a tick with different volume). Only used if wave = ticks. 0 = no marker ticks.", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MARKER_TICK_VOLUME, c.g_param_spec_double("marker-tick-volume", "Marker tick volume", "Volume of marker ticks. Only used if wave = ticks andmarker-tick-period is set to a nonzero value.", 0.0, 1.0, 1.0, cm.RW));
    c.g_object_class_install_property(oc, PROP_APPLY_TICK_RAMP, c.g_param_spec_boolean("apply-tick-ramp", "Apply tick ramp", "Apply ramp to tick samples", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_CAN_ACTIVATE_PUSH, c.g_param_spec_boolean("can-activate-push", "Can activate push", "Can activate in push mode", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_CAN_ACTIVATE_PULL, c.g_param_spec_boolean("can-activate-pull", "Can activate pull", "Can activate in pull mode", 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_set_static_metadata(ec, "Audio test source", "Source/Audio", "Creates audio test signals of given frequency and volume", "Stefan Kost <ensonic@users.sf.net>");
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.set_caps = setCaps;
    bc.fixate = fixate;
    bc.is_seekable = isSeekable;
    bc.do_seek = doSeek;
    bc.query = query;
    bc.get_times = getTimes;
    bc.start = start;
    bc.stop = stop;
    bc.fill = fill;
    c.gst_type_mark_as_plugin_api(waveType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.volume = 0.8;
    s.freq = 440.0;
    c.gst_base_src_set_format(base(s), c.GST_FORMAT_TIME);
    c.gst_base_src_set_live(base(s), 0);
    s.samples_per_buffer = 1024;
    s.gen_samples = 1024;
    s.timestamp_offset = 0;
    s.can_activate_pull = 0;
    s.periods_per_tick = 10;
    s.tick_interval = SEC;
    s.marker_period = 0;
    s.marker_volume = 1.0;
    s.tick_ramp = 0;
    s.gen = null;
    s.wave = 0;
    c.gst_base_src_set_blocksize(base(s), std.math.maxInt(c.guint));
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_base_src_get_type(), "GstAudioTestSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    _ = c._gst_debug_category_new("audiotestsrc", 0, "Audio Test Source");
    return c.gst_element_register(p, "audiotestsrc", c.GST_RANK_NONE, getType()) != 0;
}
