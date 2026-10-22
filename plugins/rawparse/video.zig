const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const base = @import("base.zig");

const FILE = "../gst/rawparse/gstrawvideoparse.c";
const PROP_WIDTH = 1;
const PROP_HEIGHT = 2;
const PROP_FORMAT = 3;
const PROP_PIXEL_ASPECT_RATIO = 4;
const PROP_FRAMERATE = 5;
const PROP_INTERLACED = 6;
const PROP_TOP_FIELD_FIRST = 7;
const PROP_PLANE_STRIDES = 8;
const PROP_PLANE_OFFSETS = 9;
const PROP_FRAME_SIZE = 10;
const PROP_COLORIMETRY = 11;

const MAX_PLANES = c.GST_VIDEO_MAX_PLANES;

pub const UNALIGNED_CAPS = "video/x-unaligned-raw, format = (string) " ++ c.GST_VIDEO_FORMATS_ALL ++ ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;
pub const RAW_CAPS = "video/x-raw, format = (string) " ++ c.GST_VIDEO_FORMATS_ALL ++ ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;
const PARSE_CAPS = RAW_CAPS ++ "; ";

const Config = extern struct {
    ready: c.gboolean,
    width: c.gint,
    height: c.gint,
    format: c.GstVideoFormat,
    par_n: c.gint,
    par_d: c.gint,
    fps_n: c.gint,
    fps_d: c.gint,
    interlaced: c.gboolean,
    plane_offsets: [MAX_PLANES]usize,
    plane_strides: [MAX_PLANES]c.gint,
    colorimetry: c.GstVideoColorimetry,
    top_field_first: c.gboolean,
    frame_size: c.guint,
    info: c.GstVideoInfo,
    custom_plane_strides: c.gboolean,
};

const Self = extern struct {
    parent: base.Self,
    properties_config: Config,
    sink_caps_config: Config,
    current_config: *Config,
};

const Class = extern struct {
    parent: base.Class,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, UNALIGNED_CAPS ++ "; " ++ PARSE_CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, PARSE_CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstBaseParseClass = null;

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

fn nPlanes(info: *const c.GstVideoInfo) c.guint {
    return info.finfo.*.n_planes;
}

fn copyPlanes(cfg: *Config) void {
    for (0..MAX_PLANES) |i| {
        cfg.plane_offsets[i] = cfg.info.offset[i];
        cfg.plane_strides[i] = cfg.info.stride[i];
    }
}

fn initConfig(cfg: *Config) void {
    cfg.ready = 0;
    cfg.width = 320;
    cfg.height = 240;
    cfg.format = c.GST_VIDEO_FORMAT_I420;
    cfg.par_n = 1;
    cfg.par_d = 1;
    cfg.fps_n = 25;
    cfg.fps_d = 1;
    cfg.interlaced = 0;
    cfg.top_field_first = 0;
    cfg.frame_size = 0;
    _ = c.gst_video_info_set_format(&cfg.info, c.GST_VIDEO_FORMAT_I420, 320, 240);
    copyPlanes(cfg);
}

fn scaleHeight(sub: c.guint, h: c.gint) c.gint {
    return -((-h) >> @intCast(sub));
}

fn updateInfo(cfg: *Config) void {
    const info = &cfg.info;
    _ = c.gst_video_info_set_format(info, cfg.format, @bitCast(cfg.width), @bitCast(cfg.height));
    info.colorimetry = cfg.colorimetry;
    info.par_n = cfg.par_n;
    info.par_d = cfg.par_d;
    info.fps_n = cfg.fps_n;
    info.fps_d = cfg.fps_d;
    info.interlace_mode = if (cfg.interlaced != 0) c.GST_VIDEO_INTERLACE_MODE_INTERLEAVED else c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
    if (cfg.custom_plane_strides != 0) {
        for (0..MAX_PLANES) |i| {
            info.offset[i] = cfg.plane_offsets[i];
            info.stride[i] = cfg.plane_strides[i];
        }
    } else copyPlanes(cfg);
    const n = @max(nPlanes(info), 1);
    var last: usize = 0;
    var last_off: usize = 0;
    for (0..n) |i| {
        if (info.offset[i] >= last_off) {
            last = i;
            last_off = info.offset[i];
        }
    }
    const fi = info.finfo;
    var size: usize = 0;
    if (fi.*.flags & c.GST_VIDEO_FORMAT_FLAG_TILED != 0) {
        const stride: c.guint = @bitCast(info.stride[last]);
        const xt: usize = stride & 0xffff;
        const yt: usize = stride >> 16;
        const tiles = fi[0].tile_info;
        size = xt * yt * tiles[last].size;
    } else {
        var comp: [c.GST_VIDEO_MAX_COMPONENTS]c.gint = undefined;
        c.gst_video_format_info_component(fi, @intCast(last), &comp);
        size = @bitCast(@as(isize, info.stride[last]) * scaleHeight(fi[0].h_sub[@intCast(comp[0])], cfg.height));
    }
    info.size = last_off + size;
}

fn propsChanged(s: *Self, invalidate: bool) void {
    if (usingSinkCaps(s)) return;
    if (invalidate) base.invalidateSrcCaps(&s.parent);
    c.gst_base_parse_set_min_frame_size(@ptrCast(s), @intCast(frameSize(&s.parent, base.PROPERTIES)));
}

fn planeArray(s: *Self, v: [*c]const c.GValue, offsets: bool) void {
    const cfg = &s.properties_config;
    if (c.gst_value_array_get_size(v) == 0) {
        cfg.custom_plane_strides = 0;
        updateInfo(cfg);
        return;
    }
    base.lock(&s.parent);
    defer base.unlock(&s.parent);
    const n = nPlanes(&cfg.info);
    if (c.gst_value_array_get_size(v) < n) {
        const text = if (offsets) "incorrect number of elements in plane offsets property" else "incorrect number of elements in plane strides property";
        cm.elementError(s, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_SETTINGS, c.g_strdup(text), c.g_strdup_printf("expected: %u, got: %u", n, c.gst_value_array_get_size(v)), FILE, "gst_raw_video_parse_set_property", if (offsets) 578 else 527);
        return;
    }
    for (0..n) |i| {
        const x = c.g_value_get_int(c.gst_value_array_get_value(v, @intCast(i)));
        if (offsets) cfg.plane_offsets[i] = @bitCast(@as(isize, x)) else cfg.plane_strides[i] = x;
    }
    cfg.custom_plane_strides = 1;
    updateInfo(cfg);
    propsChanged(s, false);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const cfg = &s.properties_config;
    switch (id) {
        PROP_WIDTH, PROP_HEIGHT, PROP_FORMAT => {
            base.lock(&s.parent);
            defer base.unlock(&s.parent);
            switch (id) {
                PROP_WIDTH => {
                    const x = c.g_value_get_int(v);
                    if (x == cfg.width) return;
                    cfg.width = x;
                },
                PROP_HEIGHT => {
                    const x = c.g_value_get_int(v);
                    if (x == cfg.height) return;
                    cfg.height = x;
                },
                else => {
                    const x: c.GstVideoFormat = @bitCast(c.g_value_get_enum(v));
                    if (x == cfg.format) return;
                    cfg.format = x;
                },
            }
            updateInfo(cfg);
            propsChanged(s, true);
        },
        PROP_PIXEL_ASPECT_RATIO => {
            base.lock(&s.parent);
            cfg.par_n = c.gst_value_get_fraction_numerator(v);
            cfg.info.par_n = cfg.par_n;
            cfg.par_d = c.gst_value_get_fraction_denominator(v);
            cfg.info.par_d = cfg.par_d;
            base.unlock(&s.parent);
        },
        PROP_FRAMERATE => {
            base.lock(&s.parent);
            cfg.fps_n = c.gst_value_get_fraction_numerator(v);
            cfg.info.fps_n = cfg.fps_n;
            cfg.fps_d = c.gst_value_get_fraction_denominator(v);
            cfg.info.fps_d = cfg.fps_d;
            base.unlock(&s.parent);
        },
        PROP_INTERLACED => {
            base.lock(&s.parent);
            cfg.interlaced = c.g_value_get_boolean(v);
            cfg.info.interlace_mode = if (cfg.interlaced != 0) c.GST_VIDEO_INTERLACE_MODE_INTERLEAVED else c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE;
            base.unlock(&s.parent);
        },
        PROP_TOP_FIELD_FIRST => {
            base.lock(&s.parent);
            cfg.top_field_first = c.g_value_get_boolean(v);
            base.unlock(&s.parent);
        },
        PROP_PLANE_STRIDES => planeArray(s, v, false),
        PROP_PLANE_OFFSETS => planeArray(s, v, true),
        PROP_FRAME_SIZE => {
            base.lock(&s.parent);
            cfg.frame_size = c.g_value_get_uint(v);
            updateInfo(cfg);
            propsChanged(s, false);
            base.unlock(&s.parent);
        },
        PROP_COLORIMETRY => {
            var ci: c.GstVideoColorimetry = undefined;
            if (c.gst_video_colorimetry_from_string(&ci, c.g_value_get_string(v)) == 0) return;
            base.lock(&s.parent);
            if (c.gst_video_colorimetry_is_equal(&ci, &cfg.info.colorimetry) == 0) {
                cfg.colorimetry = ci;
                updateInfo(cfg);
                if (!usingSinkCaps(s)) base.invalidateSrcCaps(&s.parent);
            }
            base.unlock(&s.parent);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 648),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    const cfg = &s.properties_config;
    if (id < PROP_WIDTH or id > PROP_FRAME_SIZE) return cm.warnInvalid(FILE, o, id, spec, 759);
    if (id == PROP_PLANE_STRIDES or id == PROP_PLANE_OFFSETS) _ = c.g_value_reset(v);
    base.lock(&s.parent);
    defer base.unlock(&s.parent);
    switch (id) {
        PROP_WIDTH => c.g_value_set_int(v, cfg.width),
        PROP_HEIGHT => c.g_value_set_int(v, cfg.height),
        PROP_FORMAT => c.g_value_set_enum(v, @bitCast(cfg.format)),
        PROP_PIXEL_ASPECT_RATIO => c.gst_value_set_fraction(v, cfg.par_n, cfg.par_d),
        PROP_FRAMERATE => c.gst_value_set_fraction(v, cfg.fps_n, cfg.fps_d),
        PROP_INTERLACED => c.g_value_set_boolean(v, cfg.interlaced),
        PROP_TOP_FIELD_FIRST => c.g_value_set_boolean(v, cfg.top_field_first),
        PROP_PLANE_STRIDES, PROP_PLANE_OFFSETS => {
            var val = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&val, c.G_TYPE_INT);
            for (0..nPlanes(&cfg.info)) |i| {
                c.g_value_set_int(&val, if (id == PROP_PLANE_STRIDES) cfg.plane_strides[i] else @truncate(@as(isize, @bitCast(cfg.plane_offsets[i]))));
                c.gst_value_array_append_value(v, &val);
            }
            c.g_value_unset(&val);
        },
        else => c.g_value_set_uint(v, cfg.frame_size),
    }
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

fn setConfigFromCaps(b: *base.Self, which: base.Config, caps_in: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const cfg = configPtr(me(b), which);
    var caps = c.gst_caps_ref(caps_in);
    var st = c.gst_caps_get_structure(caps, 0);
    if (c.gst_structure_has_name(st, "video/x-unaligned-raw") != 0) {
        const copy = c.gst_caps_copy(caps);
        c.gst_caps_unref(caps);
        caps = copy;
        st = c.gst_caps_get_structure(caps, 0);
        c.gst_structure_set_name(st, "video/x-raw");
    }
    cfg.ready = c.gst_video_info_from_caps(&cfg.info, caps);
    if (cfg.ready != 0) {
        cfg.width = cfg.info.width;
        cfg.height = cfg.info.height;
        cfg.format = cfg.info.finfo.*.format;
        cfg.par_n = cfg.info.par_n;
        cfg.par_d = cfg.info.par_d;
        cfg.fps_n = cfg.info.fps_n;
        cfg.fps_d = cfg.info.fps_d;
        cfg.interlaced = @intFromBool(cfg.info.interlace_mode != c.GST_VIDEO_INTERLACE_MODE_PROGRESSIVE);
        cfg.top_field_first = 0;
        cfg.frame_size = 0;
        copyPlanes(cfg);
    }
    c.gst_caps_unref(caps);
    return cfg.ready;
}

fn getCapsFromConfig(b: *base.Self, which: base.Config, caps: *[*c]c.GstCaps) callconv(.c) c.gboolean {
    caps.* = c.gst_video_info_to_caps(&configPtr(me(b), which).info);
    return @intFromBool(caps.* != null);
}

fn frameSize(b: *base.Self, which: base.Config) callconv(.c) usize {
    const cfg = configPtr(me(b), which);
    return @max(cfg.info.size, cfg.frame_size);
}

fn maxFrames(_: *base.Self, _: base.Config) callconv(.c) c.guint {
    return 1;
}

fn isReady(b: *base.Self, which: base.Config) callconv(.c) c.gboolean {
    return configPtr(me(b), which).ready;
}

fn process(b: *base.Self, which: base.Config, in: [*c]c.GstBuffer, _: usize, _: usize, outbuf: *[*c]c.GstBuffer) callconv(.c) c.gboolean {
    const cfg = configPtr(me(b), which);
    var map: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(in, &map, c.GST_MAP_READ) == 0) return 0;
    var params = c.GstAllocationParams{ .flags = 0, .@"align" = 31, .prefix = 0, .padding = 0, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
    const size = cfg.info.size;
    const o = c.gst_buffer_new_allocate(null, size, &params);
    outbuf.* = o;
    _ = c.gst_buffer_fill(o, 0, map.data, size);
    c.gst_buffer_unmap(in, &map);
    _ = c.gst_buffer_copy_into(o, in, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS, 0, size);
    var flags: c.guint = 0;
    if (cfg.interlaced != 0) {
        @as(*c.GstMiniObject, @ptrCast(o)).flags |= c.GST_VIDEO_BUFFER_FLAG_INTERLACED;
        flags |= c.GST_VIDEO_FRAME_FLAG_INTERLACED;
        if (cfg.top_field_first != 0) {
            @as(*c.GstMiniObject, @ptrCast(o)).flags |= c.GST_VIDEO_BUFFER_FLAG_TFF;
            flags |= c.GST_VIDEO_FRAME_FLAG_TFF;
        } else @as(*c.GstMiniObject, @ptrCast(o)).flags &= ~@as(c.guint, c.GST_VIDEO_BUFFER_FLAG_TFF);
    }
    _ = c.gst_buffer_add_video_meta_full(o, flags, cfg.format, @bitCast(cfg.width), @bitCast(cfg.height), nPlanes(&cfg.info), &cfg.plane_offsets, &cfg.plane_strides);
    return 1;
}

fn unitSupported(_: *base.Self, f: c.GstFormat) callconv(.c) c.gboolean {
    return @intFromBool(f == c.GST_FORMAT_BYTES or f == c.GST_FORMAT_DEFAULT);
}

fn unitsPerSecond(b: *base.Self, f: c.GstFormat, which: base.Config, n: *usize, d: *usize) callconv(.c) void {
    const cfg = configPtr(me(b), which);
    if (f == c.GST_FORMAT_BYTES) {
        const num: i64 = @as(i64, @intCast(cfg.info.size)) *% cfg.fps_n;
        const den: i64 = cfg.fps_d;
        const g = c.gst_util_greatest_common_divisor_int64(num, den);
        n.* = @bitCast(@divTrunc(num, g));
        d.* = @bitCast(@divTrunc(den, g));
    } else {
        n.* = @bitCast(@as(isize, cfg.fps_n));
        d.* = @bitCast(@as(isize, cfg.fps_d));
    }
}

fn overhead(b: *base.Self, which: base.Config) callconv(.c) c.gint {
    const cfg = configPtr(me(b), which);
    const info_size: i64 = @intCast(cfg.info.size);
    const fs: i64 = cfg.frame_size;
    return if (info_size < fs) @truncate(fs - info_size) else 0;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("rawvideoparse", 0, "rawvideoparse element");
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
    rc.get_max_frames_per_buffer = maxFrames;
    rc.is_config_ready = isReady;
    rc.process = process;
    rc.is_unit_format_supported = unitSupported;
    rc.get_units_per_second = unitsPerSecond;
    rc.get_overhead_size = overhead;
    const max = std.math.maxInt(c.gint);
    c.g_object_class_install_property(oc, PROP_WIDTH, c.g_param_spec_int("width", "Width", "Width of frames in raw stream", 0, max, 320, cm.RW));
    c.g_object_class_install_property(oc, PROP_HEIGHT, c.g_param_spec_int("height", "Height", "Height of frames in raw stream", 0, max, 240, cm.RW));
    c.g_object_class_install_property(oc, PROP_FORMAT, c.g_param_spec_enum("format", "Format", "Format of frames in raw stream", c.gst_video_format_get_type(), c.GST_VIDEO_FORMAT_I420, cm.RW));
    c.g_object_class_install_property(oc, PROP_FRAMERATE, c.gst_param_spec_fraction("framerate", "Frame rate", "Rate of frames in raw stream", 0, 1, max, 1, 25, 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_PIXEL_ASPECT_RATIO, c.gst_param_spec_fraction("pixel-aspect-ratio", "Pixel aspect ratio", "Pixel aspect ratio of frames in raw stream", 1, 100, 100, 1, 1, 1, cm.RW));
    c.g_object_class_install_property(oc, PROP_INTERLACED, c.g_param_spec_boolean("interlaced", "Interlaced flag", "True if frames in raw stream are interlaced", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TOP_FIELD_FIRST, c.g_param_spec_boolean("top-field-first", "Top field first", "True if top field in frames in raw stream come first (not used if frames aren't interlaced)", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_PLANE_STRIDES, c.gst_param_spec_array("plane-strides", "Plane strides", "Strides of the planes in bytes (e.g. plane-strides=\"<320,320>\")", c.g_param_spec_int("plane-stride", "Plane stride", "Stride of the n-th plane in bytes (0 = stride equals width*bytes-per-pixel)", 0, max, 0, cm.RW), cm.RW));
    c.g_object_class_install_property(oc, PROP_PLANE_OFFSETS, c.gst_param_spec_array("plane-offsets", "Plane offsets", "Offsets of the planes in bytes (e.g. plane-offsets=\"<0,76800>\")", c.g_param_spec_int("plane-offset", "Plane offset", "Offset of the n-th plane in bytes", 0, max, 0, cm.RW), cm.RW));
    c.g_object_class_install_property(oc, PROP_FRAME_SIZE, c.g_param_spec_uint("frame-size", "Frame size", "Size of a frame (0 = frames are tightly packed together)", 0, std.math.maxInt(c.guint), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_COLORIMETRY, c.g_param_spec_string("colorimetry", "Colorimetry", "The video source colorimetry", null, c.G_PARAM_WRITABLE | c.G_PARAM_STATIC_STRINGS));
    c.gst_element_class_set_static_metadata(ec, "rawvideoparse", "Codec/Parser/Video", "Converts unformatted data streams into timestamped raw video frames", "Carlos Rafael Giani <dv@pseudoterminal.org>");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    initConfig(&s.properties_config);
    initConfig(&s.sink_caps_config);
    s.current_config = &s.properties_config;
    s.properties_config.ready = 1;
    s.properties_config.top_field_first = 0;
    s.properties_config.frame_size = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(base.getType(), "GstRawVideoParse", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "rawvideoparse", c.GST_RANK_NONE, getType()) != 0;
}
