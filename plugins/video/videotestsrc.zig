const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pat = @import("patterns.zig");

const FILE = "../gst/videotestsrc/gstvideotestsrc.c";
const SEC: u64 = 1_000_000_000;
const RAW = "video/x-raw, format = (string) " ++ c.GST_VIDEO_FORMATS_ALL ++ ", width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE;
const BAYER = " bggr, rggb, grbg, gbrg" ++ bits("10") ++ bits("12") ++ bits("14") ++ bits("16");
const CAPS = RAW ++ ",multiview-mode = { mono, left, right };video/x-bayer, format=(string) {" ++ BAYER ++ " },width = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", height = " ++ c.GST_VIDEO_SIZE_RANGE ++ ", framerate = " ++ c.GST_VIDEO_FPS_RANGE ++ ", multiview-mode = { mono, left, right }";

fn bits(comptime n: []const u8) []const u8 {
    var s: []const u8 = "";
    for ([_][]const u8{ "le", "be" }) |e| {
        for ([_][]const u8{ "bggr", "rggb", "grbg", "gbrg" }) |m| s = s ++ ", " ++ m ++ n ++ e;
    }
    return s;
}

const PROP_PATTERN = 1;
const PROP_TIMESTAMP_OFFSET = 2;
const PROP_IS_LIVE = 3;
const PROP_K0 = 4;
const PROP_KX = 5;
const PROP_KY = 6;
const PROP_KT = 7;
const PROP_KXT = 8;
const PROP_KYT = 9;
const PROP_KXY = 10;
const PROP_KX2 = 11;
const PROP_KY2 = 12;
const PROP_KT2 = 13;
const PROP_XOFFSET = 14;
const PROP_YOFFSET = 15;
const PROP_FOREGROUND_COLOR = 16;
const PROP_BACKGROUND_COLOR = 17;
const PROP_HORIZONTAL_SPEED = 18;
const PROP_ANIMATION_MODE = 19;
const PROP_MOTION_TYPE = 20;
const PROP_FLIP = 21;

const Make = *const fn (*Self, u64, [*c]c.GstVideoFrame) void;

pub const Self = extern struct {
    parent: c.GstPushSrc,
    pattern: c.gint,
    info: c.GstVideoInfo,
    subsample: ?*c.GstVideoChromaResample,
    bayer: c.gboolean,
    bpp: c.gint,
    x_invert: c.gint,
    y_invert: c.gint,
    timestamp_offset: i64,
    running_time: u64,
    n_frames: i64,
    reverse: c.gboolean,
    accum_rtime: u64,
    accum_frames: i64,
    k0: c.gint,
    kx: c.gint,
    ky: c.gint,
    kt: c.gint,
    kxt: c.gint,
    kyt: c.gint,
    kxy: c.gint,
    kx2: c.gint,
    ky2: c.gint,
    kt2: c.gint,
    xoffset: c.gint,
    yoffset: c.gint,
    foreground_color: c.guint,
    background_color: c.guint,
    horizontal_speed: c.gint,
    random_state: c.guint,
    animation_mode: c.gint,
    motion_type: c.gint,
    flip: c.gboolean,
    make: ?Make,
    tmpline_u8: ?[*]u8,
    tmpline: ?[*]u8,
    tmpline2: ?[*]u8,
    tmpline_u16: ?[*]u16,
    n_lines: c.guint,
    offset: c.gint,
    lines: ?[*]?*anyopaque,
    cached: [*c]c.GstBuffer,
    cache_lock: c.GMutex,
    static_pattern: c.gboolean,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var pattern_once: cm.Once = .{};
var anim_once: cm.Once = .{};
var motion_once: cm.Once = .{};
var parent: ?*c.GstBaseSrcClass = null;

fn ev(v: c.gint, name: [*:0]const u8, nick: [*:0]const u8) c.GEnumValue {
    return .{ .value = v, .value_name = name, .value_nick = nick };
}

const END = c.GEnumValue{ .value = 0, .value_name = null, .value_nick = null };

var patterns = [_]c.GEnumValue{
    ev(0, "SMPTE 100% color bars", "smpte"),           ev(1, "Random (television snow)", "snow"),
    ev(2, "100% Black", "black"),                      ev(3, "100% White", "white"),
    ev(4, "Red", "red"),                               ev(5, "Green", "green"),
    ev(6, "Blue", "blue"),                             ev(7, "Checkers 1px", "checkers-1"),
    ev(8, "Checkers 2px", "checkers-2"),               ev(9, "Checkers 4px", "checkers-4"),
    ev(10, "Checkers 8px", "checkers-8"),              ev(11, "Circular", "circular"),
    ev(12, "Blink", "blink"),                          ev(13, "SMPTE 75% color bars", "smpte75"),
    ev(14, "Zone plate", "zone-plate"),                ev(15, "Gamut checkers", "gamut"),
    ev(16, "Chroma zone plate", "chroma-zone-plate"),  ev(17, "Solid color", "solid-color"),
    ev(18, "Moving ball", "ball"),                     ev(19, "SMPTE 100% color bars", "smpte100"),
    ev(20, "Bar", "bar"),                              ev(21, "Pinwheel", "pinwheel"),
    ev(22, "Spokes", "spokes"),                        ev(23, "Gradient", "gradient"),
    ev(24, "Colors", "colors"),                        ev(25, "SMPTE test pattern, RP 219 conformant", "smpte-rp-219"),
    END,
};

var anims = [_]c.GEnumValue{ ev(0, "frame count", "frames"), ev(1, "wall clock time", "wall-time"), ev(2, "running time", "running-time"), END };

var motions = [_]c.GEnumValue{ ev(0, "Ball waves back and forth, up and down", "wavy"), ev(1, "1 revolution per second", "sweep"), ev(2, "1/2 revolution per second, then reset to top", "hsweep"), END };

fn enumType(o: *cm.Once, comptime name: [*:0]const u8, comptime vals: []c.GEnumValue) c.GType {
    return o.get(struct {
        fn f() c.GType {
            return c.g_enum_register_static(name, vals.ptr);
        }
    }.f);
}

fn patternType() c.GType {
    return enumType(&pattern_once, "GstVideoTestSrcPattern", &patterns);
}

fn animType() c.GType {
    return enumType(&anim_once, "GstVideoTestSrcAnimationMode", &anims);
}

fn motionType() c.GType {
    return enumType(&motion_once, "GstVideoTestSrcMotionType", &motions);
}

const makers = [_]Make{ pat.smpte, pat.snow, pat.black, pat.white, pat.red, pat.green, pat.blue, pat.checkers1, pat.checkers2, pat.checkers4, pat.checkers8, pat.circular, pat.blink, pat.smpte75, pat.zoneplate, pat.gamut, pat.chromazoneplate, pat.solid, pat.ball, pat.smpte100, pat.bar, pat.pinwheel, pat.spokes, pat.gradient, pat.colors, pat.smpteRp219 };

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn base(p: anytype) [*c]c.GstBaseSrc {
    return @ptrCast(@alignCast(p));
}

fn setPattern(s: *Self, t: c.gint) void {
    s.pattern = t;
    if (t < 0 or t >= makers.len) {
        c.g_assertion_message_expr(null, FILE, 698, "gst_video_test_src_set_pattern", null);
        return;
    }
    s.make = makers[@intCast(t)];
}

fn isStatic(s: *Self) bool {
    switch (s.pattern) {
        0, 1, 12, 18 => return false,
        14, 16 => if (s.kxt != 0 or s.kyt != 0 or s.kt != 0 or s.kt2 != 0) return false,
        else => {},
    }
    return switch (s.pattern) {
        0, 1, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24 => s.horizontal_speed == 0,
        else => true,
    };
}

fn hasAlpha(f: [*c]const c.GstVideoFormatInfo) bool {
    return f[0].flags & c.GST_VIDEO_FORMAT_FLAG_ALPHA != 0;
}

fn alphaOnly(caps_in: [*c]c.GstCaps) [*c]c.GstCaps {
    var caps = caps_in;
    const alpha = c.gst_caps_new_empty();
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const formats = c.gst_structure_get_value(c.gst_caps_get_structure(caps, i), "format");
        if (formats != null and formats[0].g_type == c.gst_value_list_get_type()) {
            var keep = std.mem.zeroes(c.GValue);
            _ = c.g_value_init(&keep, c.gst_value_list_get_type());
            var k: c.guint = 0;
            while (k < c.gst_value_list_get_size(formats)) : (k += 1) {
                const item = c.gst_value_list_get_value(formats, k);
                if (hasAlpha(c.gst_video_format_get_info(c.gst_video_format_from_string(c.g_value_get_string(item))))) {
                    var tmp = std.mem.zeroes(c.GValue);
                    c.gst_value_init_and_copy(&tmp, item);
                    c.gst_value_list_append_value(&keep, &tmp);
                }
            }
            if (c.gst_value_list_get_size(&keep) != 0) {
                const st = c.gst_structure_copy(c.gst_caps_get_structure(caps, i));
                c.gst_structure_set_value(st, "format", &keep);
                c.gst_caps_append_structure(alpha, st);
            }
        } else if (formats != null and c.g_type_check_value_holds(formats, c.G_TYPE_STRING) != 0) {
            if (hasAlpha(c.gst_video_format_get_info(c.gst_video_format_from_string(c.g_value_get_string(formats))))) c.gst_caps_append_structure(alpha, c.gst_structure_copy(c.gst_caps_get_structure(caps, i)));
        } else c.g_assertion_message_expr(null, FILE, 498, "gst_video_test_src_src_fixate", null);
    }
    if (c.gst_caps_is_empty(alpha) == 0) _ = c.gst_mini_object_replace(@ptrCast(&caps), @ptrCast(alpha));
    c.gst_mini_object_unref(@ptrCast(alpha));
    return caps;
}

fn fixate(bs: [*c]c.GstBaseSrc, caps_in: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    var caps = caps_in;
    if (s.foreground_color >> 24 != 255) caps = alphaOnly(caps);
    caps = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(caps))));
    const st = c.gst_caps_get_structure(caps, 0);
    _ = c.gst_structure_fixate_field_nearest_int(st, "width", 320);
    _ = c.gst_structure_fixate_field_nearest_int(st, "height", 240);
    const N: ?*anyopaque = null;
    if (c.gst_structure_has_field(st, "framerate") != 0) {
        _ = c.gst_structure_fixate_field_nearest_fraction(st, "framerate", 30, 1);
    } else c.gst_structure_set(st, "framerate", c.gst_fraction_get_type(), @as(c.gint, 30), @as(c.gint, 1), N);
    if (c.gst_structure_has_field(st, "pixel-aspect-ratio") != 0) {
        _ = c.gst_structure_fixate_field_nearest_fraction(st, "pixel-aspect-ratio", 1, 1);
    } else c.gst_structure_set(st, "pixel-aspect-ratio", c.gst_fraction_get_type(), @as(c.gint, 1), @as(c.gint, 1), N);
    if (c.gst_structure_has_field(st, "colorimetry") != 0) _ = c.gst_structure_fixate_field_string(st, "colorimetry", "bt601");
    if (c.gst_structure_has_field(st, "chroma-site") != 0) _ = c.gst_structure_fixate_field_string(st, "chroma-site", "mpeg2");
    if (c.gst_structure_has_field(st, "interlace-mode") != 0) {
        _ = c.gst_structure_fixate_field_string(st, "interlace-mode", "progressive");
    } else c.gst_structure_set(st, "interlace-mode", c.G_TYPE_STRING, "progressive", N);
    const mono = c.gst_video_multiview_mode_to_caps_string(c.GST_VIDEO_MULTIVIEW_MODE_MONO);
    if (c.gst_structure_has_field(st, "multiview-mode") != 0) {
        _ = c.gst_structure_fixate_field_string(st, "multiview-mode", mono);
    } else c.gst_structure_set(st, "multiview-mode", c.G_TYPE_STRING, mono, N);
    return parent.?.fixate.?(bs, caps);
}

fn parseBayer(caps: [*c]c.GstCaps, info: *c.GstVideoInfo, s: *Self) bool {
    c.gst_video_info_init(info);
    const st = c.gst_caps_get_structure(caps, 0);
    var ok = c.gst_structure_get_int(st, "width", &info.width) != 0;
    ok = c.gst_structure_get_int(st, "height", &info.height) != 0 and ok;
    const fr = c.gst_structure_get_value(st, "framerate");
    if (fr == null) return false;
    info.fps_n = c.gst_value_get_fraction_numerator(fr);
    info.fps_d = c.gst_value_get_fraction_denominator(fr);
    if (c.gst_structure_get_string(st, "colorimetry")) |cs| _ = c.gst_video_colorimetry_from_string(&info.colorimetry, cs);
    var xi: c.gint = 0;
    var yi: c.gint = 0;
    var bpp: c.gint = 0;
    if (c.gst_structure_get_string(st, "format")) |f| {
        const str = std.mem.span(f);
        if (std.mem.startsWith(u8, str, "bggr")) {
            xi = 0;
            yi = 0;
        } else if (std.mem.startsWith(u8, str, "rggb")) {
            xi = 1;
            yi = 1;
        } else if (std.mem.startsWith(u8, str, "grbg")) {
            yi = 1;
        } else if (std.mem.startsWith(u8, str, "gbrg")) {
            xi = 1;
        } else return false;
        var big = false;
        if (str.len == 4) {
            bpp = 8;
        } else if (str.len == 8) {
            bpp = @intCast(c.g_ascii_strtoull(f + 4, null, 10));
            if (bpp & 1 != 0 or bpp < 10 or bpp > 16) return false;
            if (std.mem.endsWith(u8, str, "le")) {
                big = false;
            } else if (std.mem.endsWith(u8, str, "be")) {
                big = true;
            } else return false;
        } else return false;
        info.finfo = c.gst_video_format_get_info(if (bpp == 8) c.GST_VIDEO_FORMAT_GRAY8 else if (big) c.GST_VIDEO_FORMAT_GRAY16_BE else c.GST_VIDEO_FORMAT_GRAY16_LE);
    }
    s.bayer = 1;
    s.bpp = bpp;
    s.x_invert = xi;
    s.y_invert = yi;
    info.stride[0] = ((info.width + 3) & ~@as(c.gint, 3)) * @divTrunc(bpp + 7, 8);
    info.size = @intCast(info.stride[0] * info.height);
    return ok;
}

fn decideAllocation(bs: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    var pool: ?*c.GstBufferPool = null;
    var size: c.guint = 0;
    var min: c.guint = 0;
    var max: c.guint = 0;
    var update = false;
    if (c.gst_query_get_n_allocation_pools(q) > 0) {
        c.gst_query_parse_nth_allocation_pool(q, 0, @ptrCast(&pool), &size, &min, &max);
        size = @max(size, @as(c.guint, @truncate(s.info.size)));
        update = true;
    } else size = @truncate(s.info.size);
    if (pool == null) {
        pool = if (s.bayer != 0) c.gst_buffer_pool_new() else c.gst_video_buffer_pool_new();
        const name = c.g_strdup_printf("%s-pool", cm.obj(s).name);
        c.g_object_set(pool, "name", name, @as(?*anyopaque, null));
        c.g_free(name);
    }
    const config = c.gst_buffer_pool_get_config(pool);
    var caps: [*c]c.GstCaps = null;
    c.gst_query_parse_allocation(q, &caps, null);
    if (caps != null) c.gst_buffer_pool_config_set_params(config, caps, size, min, max);
    if (c.gst_query_find_allocation_meta(q, c.gst_video_meta_api_get_type(), null) != 0) {
        c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_META);
        if (c.gst_buffer_pool_has_option(pool, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT) != 0) c.gst_buffer_pool_config_add_option(config, c.GST_BUFFER_POOL_OPTION_VIDEO_ALIGNMENT);
    }
    _ = c.gst_buffer_pool_set_config(pool, config);
    if (update) c.gst_query_set_nth_allocation_pool(q, 0, pool, size, min, max) else c.gst_query_add_allocation_pool(q, pool, size, min, max);
    if (pool) |pl| c.gst_object_unref(pl);
    return parent.?.decide_allocation.?(bs, q);
}

fn freeLines(s: *Self) void {
    if (s.lines) |l| {
        for (l[0..s.n_lines]) |x| c.g_free(x);
    }
    c.g_free(@ptrCast(s.lines));
}

fn alloc(comptime T: type, n: usize) [*]T {
    return @ptrCast(@alignCast(c.g_malloc(n).?));
}

fn setCaps(bs: [*c]c.GstBaseSrc, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bs);
    const st = c.gst_caps_get_structure(caps, 0);
    var info: c.GstVideoInfo = undefined;
    cm.lock(s);
    if (c.gst_structure_has_name(st, "video/x-raw") != 0) {
        if (c.gst_video_info_from_caps(&info, caps) == 0) {
            cm.unlock(s);
            return 0;
        }
    } else if (c.gst_structure_has_name(st, "video/x-bayer") != 0) {
        if (!parseBayer(caps, &info, s)) {
            cm.unlock(s);
            return 0;
        }
    } else {
        cm.unlock(s);
        return 0;
    }
    if (s.subsample) |r| c.gst_video_chroma_resample_free(r);
    s.subsample = c.gst_video_chroma_resample_new(0, info.chroma_site, 0, info.finfo[0].unpack_format, -@as(c.gint, @intCast(info.finfo[0].w_sub[2])), -@as(c.gint, @intCast(info.finfo[0].h_sub[2])));
    freeLines(s);
    var n: c.guint = 1;
    var off: c.gint = 0;
    if (s.subsample) |r| c.gst_video_chroma_resample_get_info(r, &n, &off);
    const lines = alloc(?*anyopaque, @sizeOf(?*anyopaque) * n);
    const w: usize = @intCast(info.width);
    for (lines[0..n]) |*l| l.* = c.g_malloc((w + 16) * 8);
    s.lines = lines;
    s.n_lines = n;
    s.offset = off;
    s.info = info;
    c.g_free(@ptrCast(s.tmpline));
    c.g_free(@ptrCast(s.tmpline2));
    c.g_free(@ptrCast(s.tmpline_u8));
    c.g_free(@ptrCast(s.tmpline_u16));
    s.tmpline_u8 = alloc(u8, w + 8);
    s.tmpline = alloc(u8, (w + 8) * 4);
    s.tmpline2 = alloc(u8, (w + 8) * 4);
    s.tmpline_u16 = alloc(u16, (w + 16) * 8);
    s.accum_rtime +%= s.running_time;
    s.accum_frames +%= s.n_frames;
    s.running_time = 0;
    s.n_frames = 0;
    c.g_mutex_lock(&s.cache_lock);
    clearCache(s);
    c.g_mutex_unlock(&s.cache_lock);
    cm.unlock(s);
    return 1;
}

fn clearCache(s: *Self) void {
    if (s.cached != null) c.gst_mini_object_unref(@ptrCast(s.cached));
    s.cached = null;
}

fn query(bs: [*c]c.GstBaseSrc, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bs);
    switch (cm.queryType(q)) {
        c.GST_QUERY_CONVERT => {
            var sf: c.GstFormat = 0;
            var df: c.GstFormat = 0;
            var sv: i64 = 0;
            var dv: i64 = 0;
            cm.lock(s);
            c.gst_query_parse_convert(q, &sf, &sv, &df, &dv);
            const res = c.gst_video_info_convert(&s.info, sf, sv, df, &dv);
            c.gst_query_set_convert(q, sf, sv, df, dv);
            cm.unlock(s);
            return res;
        },
        c.GST_QUERY_LATENCY => {
            cm.lock(s);
            if (s.info.fps_n > 0) {
                const lat = c.gst_util_uint64_scale(SEC, @intCast(s.info.fps_d), @intCast(s.info.fps_n));
                cm.unlock(s);
                c.gst_query_set_latency(q, c.gst_base_src_is_live(bs), lat, cm.CLOCK_NONE);
                return 1;
            }
            cm.unlock(s);
            return 0;
        },
        c.GST_QUERY_DURATION => {
            if (bs[0].num_buffers != -1) {
                var f: c.GstFormat = 0;
                c.gst_query_parse_duration(q, &f, null);
                if (f == c.GST_FORMAT_TIME) {
                    var res: c.gboolean = 0;
                    cm.lock(s);
                    if (s.info.fps_n != 0) {
                        const dur = c.gst_util_uint64_scale_int_round(@as(u64, @bitCast(@as(i64, bs[0].num_buffers))) *% SEC, s.info.fps_d, s.info.fps_n);
                        res = 1;
                        c.gst_query_set_duration(q, c.GST_FORMAT_TIME, @bitCast(dur));
                    }
                    cm.unlock(s);
                    return res;
                }
                if (f == c.GST_FORMAT_BYTES) {
                    cm.lock(s);
                    c.gst_query_set_duration(q, c.GST_FORMAT_BYTES, @bitCast(@as(u64, @bitCast(@as(i64, bs[0].num_buffers))) *% s.info.size));
                    cm.unlock(s);
                    return 1;
                }
            }
            return parent.?.query.?(bs, q);
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

fn doSeek(bs: [*c]c.GstBaseSrc, seg: [*c]c.GstSegment) callconv(.c) c.gboolean {
    const s = me(bs);
    seg[0].time = seg[0].start;
    const pos = seg[0].position;
    s.reverse = @intFromBool(seg[0].rate < 0);
    const fn_: u64 = @intCast(s.info.fps_n);
    const fd: u64 = @intCast(s.info.fps_d);
    s.n_frames = if (s.info.fps_n != 0) @bitCast(c.gst_util_uint64_scale(pos, fn_, fd *% SEC)) else 0;
    s.accum_frames = 0;
    s.accum_rtime = 0;
    s.running_time = if (s.info.fps_n != 0) c.gst_util_uint64_scale(@bitCast(s.n_frames), fd *% SEC, fn_) else 0;
    if (!(s.running_time <= pos)) c.g_assertion_message_expr(null, FILE, 1257, "gst_video_test_src_do_seek", "src->running_time <= position");
    return 1;
}

fn isSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 1;
}

fn fillImage(s: *Self, b: [*c]c.GstBuffer) c.GstFlowReturn {
    if (s.info.finfo == null or s.info.finfo[0].format == c.GST_VIDEO_FORMAT_UNKNOWN) return c.GST_FLOW_NOT_NEGOTIATED;
    if (s.info.fps_n == 0 and s.n_frames == 1) return c.GST_FLOW_EOS;
    if (s.n_frames == -1) return c.GST_FLOW_EOS;
    var frame: c.GstVideoFrame = undefined;
    if (c.gst_video_frame_map(&frame, &s.info, b, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_OK;
    s.make.?(s, b[0].pts, &frame);
    var palsize: usize = 0;
    if (c.gst_video_format_get_palette(frame.info.finfo[0].format, &palsize)) |pal| {
        @memcpy(@as([*]u8, @ptrCast(frame.data[1]))[0..palsize], @as([*]const u8, @ptrCast(pal))[0..palsize]);
    }
    c.gst_video_frame_unmap(&frame);
    return c.GST_FLOW_OK;
}

fn fill(ps: [*c]c.GstPushSrc, b: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(ps);
    const pts = s.accum_rtime +% @as(u64, @bitCast(s.timestamp_offset)) +% s.running_time;
    _ = c.gst_object_sync_values(cm.obj(s), pts);
    if (s.static_pattern != 0) {
        c.g_mutex_lock(&s.cache_lock);
        if (s.cached == null) {
            s.cached = c.gst_buffer_new_allocate(null, s.info.size, null);
            const ret = fillImage(s, s.cached);
            if (ret != c.GST_FLOW_OK) {
                c.g_mutex_unlock(&s.cache_lock);
                return ret;
            }
        }
        var sf: c.GstVideoFrame = undefined;
        var df: c.GstVideoFrame = undefined;
        _ = c.gst_video_frame_map(&sf, &s.info, s.cached, c.GST_MAP_READ);
        _ = c.gst_video_frame_map(&df, &s.info, b, c.GST_MAP_WRITE);
        if (c.gst_video_frame_copy(&df, &sf) == 0) {
            c.g_mutex_unlock(&s.cache_lock);
            return c.GST_FLOW_ERROR;
        }
        c.gst_video_frame_unmap(&sf);
        c.gst_video_frame_unmap(&df);
        c.g_mutex_unlock(&s.cache_lock);
    } else {
        const ret = fillImage(s, b);
        if (ret != c.GST_FLOW_OK) return ret;
    }
    b[0].pts = pts;
    b[0].dts = cm.CLOCK_NONE;
    b[0].offset = @bitCast(s.accum_frames +% s.n_frames);
    if (s.reverse != 0) s.n_frames -%= 1 else s.n_frames +%= 1;
    b[0].offset_end = b[0].offset +% 1;
    var next: u64 = 0;
    if (s.info.fps_n != 0) {
        const fn_: u64 = @intCast(s.info.fps_n);
        const fd: u64 = @intCast(s.info.fps_d);
        next = c.gst_util_uint64_scale(@bitCast(s.n_frames), fd *% SEC, fn_);
        if (s.reverse != 0) {
            const prev = c.gst_util_uint64_scale(@bitCast(s.n_frames +% 2), fd *% SEC, fn_);
            b[0].duration = prev -% b[0].pts;
        } else b[0].duration = next -% s.running_time;
    } else {
        next = @bitCast(s.timestamp_offset);
        b[0].duration = cm.CLOCK_NONE;
    }
    s.running_time = next;
    return c.GST_FLOW_OK;
}

fn start(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    cm.lock(s);
    s.running_time = 0;
    s.n_frames = 0;
    s.accum_frames = 0;
    s.accum_rtime = 0;
    c.gst_video_info_init(&s.info);
    cm.unlock(s);
    return 1;
}

fn stop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    c.g_free(@ptrCast(s.tmpline));
    s.tmpline = null;
    c.g_free(@ptrCast(s.tmpline2));
    s.tmpline2 = null;
    c.g_free(@ptrCast(s.tmpline_u8));
    s.tmpline_u8 = null;
    c.g_free(@ptrCast(s.tmpline_u16));
    s.tmpline_u16 = null;
    if (s.subsample) |r| c.gst_video_chroma_resample_free(r);
    s.subsample = null;
    freeLines(s);
    s.n_lines = 0;
    s.lines = null;
    c.g_mutex_lock(&s.cache_lock);
    clearCache(s);
    c.g_mutex_unlock(&s.cache_lock);
    return 1;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    var invalidate = true;
    switch (id) {
        PROP_PATTERN => setPattern(s, c.g_value_get_enum(v)),
        PROP_TIMESTAMP_OFFSET => {
            s.timestamp_offset = c.g_value_get_int64(v);
            invalidate = false;
        },
        PROP_IS_LIVE => {
            c.gst_base_src_set_live(base(s), c.g_value_get_boolean(v));
            invalidate = false;
        },
        PROP_K0 => s.k0 = c.g_value_get_int(v),
        PROP_KX => s.kx = c.g_value_get_int(v),
        PROP_KY => s.ky = c.g_value_get_int(v),
        PROP_KT => s.kt = c.g_value_get_int(v),
        PROP_KXT => s.kxt = c.g_value_get_int(v),
        PROP_KYT => s.kyt = c.g_value_get_int(v),
        PROP_KXY => s.kxy = c.g_value_get_int(v),
        PROP_KX2 => s.kx2 = c.g_value_get_int(v),
        PROP_KY2 => s.ky2 = c.g_value_get_int(v),
        PROP_KT2 => s.kt2 = c.g_value_get_int(v),
        PROP_XOFFSET => s.xoffset = c.g_value_get_int(v),
        PROP_YOFFSET => s.yoffset = c.g_value_get_int(v),
        PROP_FOREGROUND_COLOR => s.foreground_color = c.g_value_get_uint(v),
        PROP_BACKGROUND_COLOR => s.background_color = c.g_value_get_uint(v),
        PROP_HORIZONTAL_SPEED => s.horizontal_speed = c.g_value_get_int(v),
        PROP_ANIMATION_MODE => s.animation_mode = c.g_value_get_enum(v),
        PROP_MOTION_TYPE => s.motion_type = c.g_value_get_enum(v),
        PROP_FLIP => s.flip = c.g_value_get_boolean(v),
        else => {},
    }
    if (invalidate) {
        c.g_mutex_lock(&s.cache_lock);
        s.static_pattern = @intFromBool(isStatic(s));
        clearCache(s);
        c.g_mutex_unlock(&s.cache_lock);
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_PATTERN => c.g_value_set_enum(v, s.pattern),
        PROP_TIMESTAMP_OFFSET => c.g_value_set_int64(v, s.timestamp_offset),
        PROP_IS_LIVE => c.g_value_set_boolean(v, c.gst_base_src_is_live(base(s))),
        PROP_K0 => c.g_value_set_int(v, s.k0),
        PROP_KX => c.g_value_set_int(v, s.kx),
        PROP_KY => c.g_value_set_int(v, s.ky),
        PROP_KT => c.g_value_set_int(v, s.kt),
        PROP_KXT => c.g_value_set_int(v, s.kxt),
        PROP_KYT => c.g_value_set_int(v, s.kyt),
        PROP_KXY => c.g_value_set_int(v, s.kxy),
        PROP_KX2 => c.g_value_set_int(v, s.kx2),
        PROP_KY2 => c.g_value_set_int(v, s.ky2),
        PROP_KT2 => c.g_value_set_int(v, s.kt2),
        PROP_XOFFSET => c.g_value_set_int(v, s.xoffset),
        PROP_YOFFSET => c.g_value_set_int(v, s.yoffset),
        PROP_FOREGROUND_COLOR => c.g_value_set_uint(v, s.foreground_color),
        PROP_BACKGROUND_COLOR => c.g_value_set_uint(v, s.background_color),
        PROP_HORIZONTAL_SPEED => c.g_value_set_int(v, s.horizontal_speed),
        PROP_ANIMATION_MODE => c.g_value_set_enum(v, s.animation_mode),
        PROP_MOTION_TYPE => c.g_value_set_enum(v, s.motion_type),
        PROP_FLIP => c.g_value_set_boolean(v, s.flip),
        else => cm.warnInvalid(FILE, o, id, spec, 859),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_mutex_clear(&me(o).cache_lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn intProp(oc: *c.GObjectClass, id: c.guint, name: [*:0]const u8, nick: [*:0]const u8, blurb: [*:0]const u8) void {
    c.g_object_class_install_property(oc, id, c.g_param_spec_int(name, nick, blurb, std.math.minInt(i32), std.math.maxInt(i32), 0, cm.RW));
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, PROP_PATTERN, c.g_param_spec_enum("pattern", "Pattern", "Type of test pattern to generate", patternType(), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_ANIMATION_MODE, c.g_param_spec_enum("animation-mode", "Animation mode", "For pattern=ball, which counter defines the position of the ball.", animType(), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_MOTION_TYPE, c.g_param_spec_enum("motion", "Motion", "For pattern=ball, what motion the ball does", motionType(), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_FLIP, c.g_param_spec_boolean("flip", "Flip", "For pattern=ball, invert colors every second.", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_TIMESTAMP_OFFSET, c.g_param_spec_int64("timestamp-offset", "Timestamp offset", "An offset added to timestamps set on buffers (in ns)", 0, std.math.maxInt(i64), 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_IS_LIVE, c.g_param_spec_boolean("is-live", "Is Live", "Whether to act as a live source", 0, cm.RW));
    intProp(oc, PROP_K0, "k0", "Zoneplate zero order phase", "Zoneplate zero order phase, for generating plain fields or phase offsets");
    intProp(oc, PROP_KX, "kx", "Zoneplate 1st order x phase", "Zoneplate 1st order x phase, for generating constant horizontal frequencies");
    intProp(oc, PROP_KY, "ky", "Zoneplate 1st order y phase", "Zoneplate 1st order y phase, for generating content vertical frequencies");
    intProp(oc, PROP_KT, "kt", "Zoneplate 1st order t phase", "Zoneplate 1st order t phase, for generating phase rotation as a function of time");
    intProp(oc, PROP_KXT, "kxt", "Zoneplate x*t product phase", "Zoneplate x*t product phase, normalised to kxy/256 cycles per vertical pixel at width/2 from origin");
    intProp(oc, PROP_KYT, "kyt", "Zoneplate y*t product phase", "Zoneplate y*t product phase");
    intProp(oc, PROP_KXY, "kxy", "Zoneplate x*y product phase", "Zoneplate x*y product phase");
    intProp(oc, PROP_KX2, "kx2", "Zoneplate 2nd order x phase", "Zoneplate 2nd order x phase, normalised to kx2/256 cycles per horizontal pixel at width/2 from origin");
    intProp(oc, PROP_KY2, "ky2", "Zoneplate 2nd order y phase", "Zoneplate 2nd order y phase, normailsed to ky2/256 cycles per vertical pixel at height/2 from origin");
    intProp(oc, PROP_KT2, "kt2", "Zoneplate 2nd order t phase", "Zoneplate 2nd order t phase, t*t/256 cycles per picture");
    intProp(oc, PROP_XOFFSET, "xoffset", "Zoneplate 2nd order products x offset", "Zoneplate 2nd order products x offset");
    intProp(oc, PROP_YOFFSET, "yoffset", "Zoneplate 2nd order products y offset", "Zoneplate 2nd order products y offset");
    const CT = cm.RW | c.GST_PARAM_CONTROLLABLE;
    c.g_object_class_install_property(oc, PROP_FOREGROUND_COLOR, c.g_param_spec_uint("foreground-color", "Foreground Color", "Foreground color to use (big-endian ARGB)", 0, std.math.maxInt(u32), 0xffffffff, CT));
    c.g_object_class_install_property(oc, PROP_BACKGROUND_COLOR, c.g_param_spec_uint("background-color", "Background Color", "Background color to use (big-endian ARGB)", 0, std.math.maxInt(u32), 0xff000000, CT));
    c.g_object_class_install_property(oc, PROP_HORIZONTAL_SPEED, c.g_param_spec_int("horizontal-speed", "Horizontal Speed", "Scroll image number of pixels per frame (positive is scroll to the left)", std.math.minInt(i32), std.math.maxInt(i32), 0, cm.RW));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Video test source", "Source/Video", "Creates a test video stream", "David A. Schleef <ds@schleef.org>");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.set_caps = setCaps;
    bc.fixate = fixate;
    bc.is_seekable = isSeekable;
    bc.do_seek = doSeek;
    bc.query = query;
    bc.get_times = getTimes;
    bc.start = start;
    bc.stop = stop;
    bc.decide_allocation = decideAllocation;
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.fill = fill;
    c.gst_type_mark_as_plugin_api(animType(), 0);
    c.gst_type_mark_as_plugin_api(motionType(), 0);
    c.gst_type_mark_as_plugin_api(patternType(), 0);
    _ = c._gst_debug_category_new("videotestsrc", 0, "Video Test Source");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    setPattern(s, 0);
    s.timestamp_offset = 0;
    s.foreground_color = 0xffffffff;
    s.background_color = 0xff000000;
    s.horizontal_speed = 0;
    s.random_state = 0;
    c.gst_base_src_set_format(base(s), c.GST_FORMAT_TIME);
    c.gst_base_src_set_live(base(s), 0);
    s.animation_mode = 0;
    s.motion_type = 0;
    s.flip = 0;
    c.g_mutex_init(&s.cache_lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstVideoTestSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "videotestsrc", c.GST_RANK_NONE, getType()) != 0;
}
