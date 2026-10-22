const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const base = @import("base.zig");

const FILE = "../gst/rawparse/gstrawaudioparse.c";
const PROP_FORMAT = 1;
const PROP_PCM_FORMAT = 2;
const PROP_SAMPLE_RATE = 3;
const PROP_NUM_CHANNELS = 4;
const PROP_INTERLEAVED = 5;
const PROP_CHANNEL_POSITIONS = 6;

const PCM = 0;
const MULAW = 1;
const ALAW = 2;

pub const UNALIGNED_CAPS = "audio/x-unaligned-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = (int) [ 1, MAX ], channels = (int) [ 1, MAX ], layout = (string) { interleaved, non-interleaved }";
const PARSE_CAPS = "audio/x-raw, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", channels = " ++ c.GST_AUDIO_CHANNELS_RANGE ++ ", layout = (string) { interleaved, non-interleaved }; audio/x-alaw, rate = (int) [ 1, MAX ], channels = (int) [ 1, MAX ]; audio/x-mulaw, rate = (int) [ 1, MAX ], channels = (int) [ 1, MAX ]; ";

const Config = extern struct {
    ready: c.gboolean,
    format: c_uint,
    pcm_format: c.GstAudioFormat,
    bpf: c.guint,
    sample_rate: c.guint,
    num_channels: c.guint,
    interleaved: c.gboolean,
    channel_positions: [64]c.GstAudioChannelPosition,
    reordered_channel_positions: [64]c.GstAudioChannelPosition,
    needs_channel_reordering: c.gboolean,
};

const Self = extern struct {
    parent: base.Self,
    current_config: *Config,
    properties_config: Config,
    sink_caps_config: Config,
};

const Class = extern struct {
    parent: base.Class,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, UNALIGNED_CAPS ++ "; " ++ PARSE_CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, PARSE_CAPS);
var once: cm.Once = .{};
var format_once: cm.Once = .{};
var parent: ?*c.GstBaseParseClass = null;

const formats = [_]c.GEnumValue{
    .{ .value = PCM, .value_name = "PCM", .value_nick = "pcm" },
    .{ .value = ALAW, .value_name = "A-Law", .value_nick = "alaw" },
    .{ .value = MULAW, .value_name = "\xc2\xb5-Law", .value_nick = "mulaw" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};

fn formatType() c.GType {
    return format_once.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static("GstRawAudioParseFormat", &formats);
        }
    }.f);
}

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn usingSinkCaps(s: *Self) bool {
    return s.current_config == &s.sink_caps_config;
}

fn configPtr(s: *Self, cfg: base.Config) *Config {
    return switch (cfg) {
        base.PROPERTIES => &s.properties_config,
        base.SINKCAPS => &s.sink_caps_config,
        else => s.current_config,
    };
}

fn setChannels(cfg: *Config, n: c.guint, mask_in: u64, positions: bool) bool {
    cfg.num_channels = n;
    cfg.needs_channel_reordering = 0;
    if (!positions) return true;
    const mask = if (mask_in == 0) c.gst_audio_channel_get_fallback_mask(@intCast(n)) else mask_in;
    return c.gst_audio_channel_positions_from_mask(@intCast(n), mask, &cfg.channel_positions) != 0;
}

fn updateReordering(cfg: *Config) bool {
    if (c.gst_audio_check_valid_channel_positions(&cfg.channel_positions, @intCast(cfg.num_channels), 1) != 0) {
        cfg.needs_channel_reordering = 0;
        return true;
    }
    cfg.needs_channel_reordering = 1;
    @memcpy(cfg.reordered_channel_positions[0..cfg.num_channels], cfg.channel_positions[0..cfg.num_channels]);
    return c.gst_audio_channel_positions_to_valid_order(&cfg.reordered_channel_positions, @intCast(cfg.num_channels)) != 0;
}

fn updateBpf(cfg: *Config) void {
    switch (cfg.format) {
        PCM => cfg.bpf = @intCast(@as(c.guint, @intCast(c.gst_audio_format_get_info(cfg.pcm_format).*.width)) * cfg.num_channels / 8),
        else => cfg.bpf = cfg.num_channels,
    }
}

fn initConfig(cfg: *Config) void {
    cfg.ready = 0;
    cfg.format = PCM;
    cfg.pcm_format = c.GST_AUDIO_FORMAT_S16LE;
    cfg.bpf = 0;
    cfg.sample_rate = 44100;
    cfg.num_channels = 2;
    cfg.interleaved = 1;
    cfg.needs_channel_reordering = 0;
    _ = setChannels(cfg, cfg.num_channels, 0, true);
}

fn propsChanged(s: *Self, min_size: bool) void {
    if (usingSinkCaps(s)) return;
    base.invalidateSrcCaps(&s.parent);
    if (min_size) c.gst_base_parse_set_min_frame_size(@ptrCast(s), s.properties_config.bpf);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const cfg = &s.properties_config;
    switch (id) {
        PROP_FORMAT => {
            base.lock(&s.parent);
            const f: c_uint = @bitCast(c.g_value_get_enum(v));
            if (f != cfg.format) {
                cfg.format = f;
                updateBpf(cfg);
                propsChanged(s, true);
            }
            base.unlock(&s.parent);
        },
        PROP_PCM_FORMAT => {
            base.lock(&s.parent);
            const f: c.GstAudioFormat = @bitCast(c.g_value_get_enum(v));
            if (f != cfg.pcm_format) {
                cfg.pcm_format = f;
                updateBpf(cfg);
                propsChanged(s, true);
            }
            base.unlock(&s.parent);
        },
        PROP_SAMPLE_RATE => {
            base.lock(&s.parent);
            const r: c.guint = @bitCast(c.g_value_get_int(v));
            if (r != cfg.sample_rate) {
                cfg.sample_rate = r;
                propsChanged(s, false);
            }
            base.unlock(&s.parent);
        },
        PROP_NUM_CHANNELS => {
            base.lock(&s.parent);
            const n: c.guint = @bitCast(c.g_value_get_int(v));
            if (n != cfg.num_channels) {
                _ = setChannels(cfg, n, 0, true);
                cfg.num_channels = n;
                updateBpf(cfg);
                propsChanged(s, true);
            }
            base.unlock(&s.parent);
        },
        PROP_INTERLEAVED => {
            base.lock(&s.parent);
            const il = c.g_value_get_boolean(v);
            if (il != cfg.interleaved) {
                cfg.interleaved = il;
                propsChanged(s, false);
            }
            base.unlock(&s.parent);
        },
        PROP_CHANNEL_POSITIONS => {
            const arr: ?*c.GValueArray = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
            if (arr != null and arr.?.n_values == 0) {
                cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_SETTINGS, c.g_strdup("channel position property holds an empty array"), null, FILE, "gst_raw_audio_parse_set_property", 437);
                return;
            }
            base.lock(&s.parent);
            if (arr == null and cfg.num_channels > 0) {
                _ = setChannels(cfg, cfg.num_channels, 0, true);
            } else if (arr) |a| {
                if (a.n_values != cfg.num_channels) _ = setChannels(cfg, a.n_values, 0, false);
                for (0..cfg.num_channels) |i| cfg.channel_positions[i] = c.g_value_get_enum(c.g_value_array_get_nth(a, @intCast(i)));
                _ = updateReordering(cfg);
            }
            updateBpf(cfg);
            propsChanged(s, true);
            base.unlock(&s.parent);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 494),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const cfg = &s.properties_config;
    if (id < PROP_FORMAT or id > PROP_CHANNEL_POSITIONS) return cm.warnInvalid(FILE, o, id, spec, 574);
    base.lock(&s.parent);
    switch (id) {
        PROP_FORMAT => c.g_value_set_enum(v, @bitCast(cfg.format)),
        PROP_PCM_FORMAT => c.g_value_set_enum(v, @bitCast(cfg.pcm_format)),
        PROP_SAMPLE_RATE => c.g_value_set_int(v, @bitCast(cfg.sample_rate)),
        PROP_NUM_CHANNELS => c.g_value_set_int(v, @bitCast(cfg.num_channels)),
        PROP_INTERLEAVED => c.g_value_set_boolean(v, cfg.interleaved),
        else => {
            var arr: ?*c.GValueArray = null;
            if (cfg.num_channels > 0) {
                var val = std.mem.zeroes(c.GValue);
                _ = c.g_value_init(&val, c.gst_audio_channel_position_get_type());
                arr = c.g_value_array_new(cfg.num_channels);
                for (0..cfg.num_channels) |i| {
                    c.g_value_set_enum(&val, cfg.channel_positions[i]);
                    _ = c.g_value_array_insert(arr, @intCast(i), &val);
                }
                c.g_value_unset(&val);
            }
            base.unlock(&s.parent);
            c.g_value_take_boxed(v, arr);
            return;
        },
    }
    base.unlock(&s.parent);
}

fn stop(p: [*c]c.GstBaseParse) callconv(.c) c.gboolean {
    me(p).sink_caps_config.ready = 0;
    return parent.?.stop.?(p);
}

fn setCurrentConfig(b: *base.Self, cfg: base.Config) callconv(.c) c.gboolean {
    const s = me(b);
    s.current_config = if (cfg == base.PROPERTIES) &s.properties_config else &s.sink_caps_config;
    return 1;
}

fn getCurrentConfig(b: *base.Self) callconv(.c) base.Config {
    return if (usingSinkCaps(me(b))) base.SINKCAPS else base.PROPERTIES;
}

fn capsToConfig(caps_in: [*c]c.GstCaps, cfg: *Config) bool {
    var caps = c.gst_caps_ref(caps_in);
    defer c.gst_caps_unref(caps);
    var st = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_name(st, "audio/x-unaligned-raw") != 0) {
        const copy = c.gst_caps_copy(caps);
        c.gst_caps_unref(caps);
        caps = copy;
        st = c.gst_caps_get_structure(caps, 0);
        c.gst_structure_set_name(st, "audio/x-raw");
    }
    if (c.gst_structure_has_name(st, "audio/x-raw") != 0) {
        var info: c.GstAudioInfo = undefined;
        if (c.gst_audio_info_from_caps(&info, caps) == 0) return false;
        const n: c.guint = @intCast(info.channels);
        cfg.format = PCM;
        cfg.pcm_format = info.finfo.*.format;
        cfg.bpf = @intCast(info.bpf);
        cfg.sample_rate = @intCast(info.rate);
        cfg.interleaved = @intFromBool(info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED);
        _ = setChannels(cfg, n, 0, false);
        @memcpy(cfg.channel_positions[0..n], info.position[0..n]);
    } else if (c.gst_structure_has_name(st, "audio/x-alaw") != 0 or c.gst_structure_has_name(st, "audio/x-mulaw") != 0) {
        cfg.format = if (c.gst_structure_has_name(st, "audio/x-alaw") != 0) ALAW else MULAW;
        var i: c.gint = 0;
        if (c.gst_structure_get_int(st, "rate", &i) == 0) return false;
        cfg.sample_rate = @bitCast(i);
        if (c.gst_structure_get_int(st, "channels", &i) == 0) return false;
        const n: c.guint = @bitCast(i);
        var mask: u64 = 0;
        if (c.gst_structure_get(st, "channel-mask", c.gst_bitmask_get_type(), &mask, @as(?*anyopaque, null)) == 0) mask = c.gst_audio_channel_get_fallback_mask(i);
        if (!setChannels(cfg, n, mask, true)) return false;
        cfg.bpf = n;
    } else return false;
    cfg.ready = 1;
    return true;
}

fn setConfigFromCaps(b: *base.Self, cfg: base.Config, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return @intFromBool(capsToConfig(caps, configPtr(me(b), cfg)));
}

fn getCapsFromConfig(b: *base.Self, which: base.Config, caps: *[*c]c.GstCaps) callconv(.c) c.gboolean {
    const cfg = configPtr(me(b), which);
    if (cfg.bpf == 0) {
        caps.* = null;
        return 0;
    }
    const pos: [*c]c.GstAudioChannelPosition = if (cfg.needs_channel_reordering != 0) &cfg.reordered_channel_positions else &cfg.channel_positions;
    if (cfg.format == PCM) {
        var info: c.GstAudioInfo = undefined;
        c.gst_audio_info_init(&info);
        c.gst_audio_info_set_format(&info, cfg.pcm_format, @intCast(cfg.sample_rate), @intCast(cfg.num_channels), pos);
        caps.* = c.gst_audio_info_to_caps(&info);
        return 1;
    }
    var mask: u64 = 0;
    if (c.gst_audio_channel_positions_to_mask(pos, @intCast(cfg.num_channels), 1, &mask) == 0) {
        caps.* = null;
        return 0;
    }
    caps.* = c.gst_caps_new_simple(if (cfg.format == ALAW) "audio/x-alaw" else "audio/x-mulaw", "rate", c.G_TYPE_INT, cfg.sample_rate, "channels", c.G_TYPE_INT, cfg.num_channels, "channel-mask", c.gst_bitmask_get_type(), mask, @as(?*anyopaque, null));
    return 1;
}

fn frameSize(b: *base.Self, cfg: base.Config) callconv(.c) usize {
    return configPtr(me(b), cfg).bpf;
}

fn isReady(b: *base.Self, cfg: base.Config) callconv(.c) c.gboolean {
    return configPtr(me(b), cfg).ready;
}

fn roundUpPow2(x: c.guint) c.guint {
    var n = x -% 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n +% 1;
}

fn getAlignment(b: *base.Self, which: base.Config) callconv(.c) c.gint {
    const cfg = configPtr(me(b), which);
    if (cfg.format != PCM) return 1;
    var w: c.guint = @intCast(@divTrunc(c.gst_audio_format_get_info(cfg.pcm_format).*.width, 8));
    w = (w + 7) & ~@as(c.guint, 7);
    return @intCast(roundUpPow2(w));
}

fn process(b: *base.Self, which: base.Config, in: [*c]c.GstBuffer, _: usize, valid: usize, outbuf: *[*c]c.GstBuffer) callconv(.c) c.gboolean {
    const cfg = configPtr(me(b), which);
    if (cfg.format == PCM and cfg.needs_channel_reordering != 0) {
        const o = c.gst_buffer_copy_region(in, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS | c.GST_BUFFER_COPY_META | c.GST_BUFFER_COPY_MEMORY, 0, valid);
        _ = c.gst_audio_buffer_reorder_channels(o, cfg.pcm_format, @intCast(cfg.num_channels), &cfg.channel_positions, &cfg.reordered_channel_positions);
        outbuf.* = o;
    } else outbuf.* = null;
    return 1;
}

fn unitSupported(_: *base.Self, f: c.GstFormat) callconv(.c) c.gboolean {
    return @intFromBool(f == c.GST_FORMAT_BYTES or f == c.GST_FORMAT_DEFAULT);
}

fn unitsPerSecond(b: *base.Self, f: c.GstFormat, which: base.Config, n: *usize, d: *usize) callconv(.c) void {
    const cfg = configPtr(me(b), which);
    n.* = if (f == c.GST_FORMAT_BYTES) @as(usize, cfg.sample_rate *% cfg.bpf) else cfg.sample_rate;
    d.* = 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("rawaudioparse", 0, "rawaudioparse element");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&sink_t));
    c.gst_element_class_add_pad_template(ec, c.gst_static_pad_template_get(&src_t));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    @as(*c.GstBaseParseClass, @ptrCast(@alignCast(k))).stop = stop;
    const rc: *base.Class = @ptrCast(@alignCast(k));
    rc.set_current_config = setCurrentConfig;
    rc.get_current_config = getCurrentConfig;
    rc.set_config_from_caps = setConfigFromCaps;
    rc.get_caps_from_config = getCapsFromConfig;
    rc.get_config_frame_size = frameSize;
    rc.is_config_ready = isReady;
    rc.process = process;
    rc.is_unit_format_supported = unitSupported;
    rc.get_units_per_second = unitsPerSecond;
    rc.get_alignment = getAlignment;
    c.g_object_class_install_property(oc, PROP_FORMAT, c.g_param_spec_enum("format", "Format", "Format of the raw audio stream", formatType(), PCM, cm.RW));
    c.g_object_class_install_property(oc, PROP_PCM_FORMAT, c.g_param_spec_enum("pcm-format", "PCM format", "Format of audio samples in PCM stream (ignored if format property is not set to pcm)", c.gst_audio_format_get_type(), PCM, cm.RW));
    c.g_object_class_install_property(oc, PROP_SAMPLE_RATE, c.g_param_spec_int("sample-rate", "Sample rate", "Rate of audio samples in raw stream", 1, std.math.maxInt(c.gint), 44100, cm.RW));
    c.g_object_class_install_property(oc, PROP_NUM_CHANNELS, c.g_param_spec_int("num-channels", "Number of channels", "Number of channels in raw stream", 1, std.math.maxInt(c.gint), 2, cm.RW));
    c.g_object_class_install_property(oc, PROP_INTERLEAVED, c.g_param_spec_boolean("interleaved", "Interleaved layout", "True if audio has interleaved layout", 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_CHANNEL_POSITIONS, c.g_param_spec_value_array("channel-positions", "Channel positions", "Channel positions used on the output", c.g_param_spec_enum("channel-position", "Channel position", "Channel position of the n-th input", c.gst_audio_channel_position_get_type(), c.GST_AUDIO_CHANNEL_POSITION_NONE, cm.RW), cm.RW));
    c.gst_element_class_set_static_metadata(ec, "rawaudioparse", "Codec/Parser/Audio", "Converts unformatted data streams into timestamped raw audio frames", "Carlos Rafael Giani <dv@pseudoterminal.org>");
    c.gst_type_mark_as_plugin_api(formatType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    initConfig(&s.properties_config);
    initConfig(&s.sink_caps_config);
    s.current_config = &s.properties_config;
    s.properties_config.ready = 1;
    updateBpf(&s.properties_config);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstRawAudioParse", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "rawaudioparse", c.GST_RANK_NONE, getType()) != 0;
}
