const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mode = c.GstVideoMultiviewMode;
const Info = c.GstVideoInfo;

var flagset_type: c.GType = 0;

pub export fn gst_video_multiview_flagset_get_type() c.GType {
    if (c.g_once_init_enter(&flagset_type) != 0) {
        const t = c.gst_flagset_register(c.gst_video_multiview_flags_get_type());
        c.g_once_init_leave(&flagset_type, t);
    }
    return flagset_type;
}

const modes = [_]struct { [*:0]const u8, Mode }{
    .{ "mono", c.GST_VIDEO_MULTIVIEW_MODE_MONO },
    .{ "left", c.GST_VIDEO_MULTIVIEW_MODE_LEFT },
    .{ "right", c.GST_VIDEO_MULTIVIEW_MODE_RIGHT },
    .{ "side-by-side", c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE },
    .{ "side-by-side-quincunx", c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX },
    .{ "column-interleaved", c.GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED },
    .{ "row-interleaved", c.GST_VIDEO_MULTIVIEW_MODE_ROW_INTERLEAVED },
    .{ "top-bottom", c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM },
    .{ "checkerboard", c.GST_VIDEO_MULTIVIEW_MODE_CHECKERBOARD },
    .{ "frame-by-frame", c.GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME },
    .{ "multiview-frame-by-frame", c.GST_VIDEO_MULTIVIEW_MODE_MULTIVIEW_FRAME_BY_FRAME },
    .{ "separated", c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED },
};

pub export fn gst_video_multiview_mode_to_caps_string(mode: Mode) [*c]const u8 {
    for (modes) |e| if (e[1] == mode) return e[0];
    return null;
}

pub export fn gst_video_multiview_mode_from_caps_string(s: [*c]const u8) Mode {
    for (modes) |e| if (c.strcmp(e[0], s) == 0) return e[1];
    c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "Invalid multiview info %s", s);
    return c.GST_VIDEO_MULTIVIEW_MODE_NONE;
}

var values = std.mem.zeroes([5]c.GValue);
var values_once: c.gsize = 0;

const groups = [5][]const [*:0]const u8{
    &.{ "mono", "left", "right" },
    &.{ "separated", "frame-by-frame", "multiview-frame-by-frame" },
    &.{ "top-bottom", "row-interleaved" },
    &.{ "side-by-side", "side-by-side-quincunx", "column-interleaved" },
    &.{"checkerboard"},
};

fn init() void {
    if (c.g_once_init_enter(&values_once) == 0) return;
    var item = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.G_TYPE_STRING);
    for (groups, 0..) |g, k| {
        _ = c.g_value_init(&values[k], c.gst_value_list_get_type());
        for (g) |name| {
            c.g_value_set_static_string(&item, name);
            c.gst_value_list_append_value(&values[k], &item);
        }
    }
    c.g_value_unset(&item);
    c.g_once_init_leave(&values_once, 1);
}

pub export fn gst_video_multiview_get_mono_modes() *const c.GValue {
    init();
    return &values[0];
}

pub export fn gst_video_multiview_get_unpacked_modes() *const c.GValue {
    init();
    return &values[1];
}

pub export fn gst_video_multiview_get_doubled_height_modes() *const c.GValue {
    init();
    return &values[2];
}

pub export fn gst_video_multiview_get_doubled_width_modes() *const c.GValue {
    init();
    return &values[3];
}

pub export fn gst_video_multiview_get_doubled_size_modes() *const c.GValue {
    init();
    return &values[4];
}

fn wide(mode: Mode) bool {
    return switch (mode) {
        c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE, c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX, c.GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED, c.GST_VIDEO_MULTIVIEW_MODE_CHECKERBOARD => true,
        else => false,
    };
}

fn tall(mode: Mode) bool {
    return mode == c.GST_VIDEO_MULTIVIEW_MODE_ROW_INTERLEAVED or mode == c.GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM;
}

const HALF = c.GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT;

pub export fn gst_video_multiview_video_info_change_mode(info: *Info, out_mode: Mode, out_flags: c.GstVideoMultiviewFlags) void {
    const abi = &info.ABI.abi;
    const mode = abi.multiview_mode;
    if (wide(mode)) {
        info.width = @divTrunc(info.width, 2);
        info.views *= 2;
        abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED;
        if (abi.multiview_flags & HALF != 0) info.par_n *= 2;
    } else if (tall(mode)) {
        info.height = @divTrunc(info.height, 2);
        info.views *= 2;
        abi.multiview_mode = c.GST_VIDEO_MULTIVIEW_MODE_SEPARATED;
        if (abi.multiview_flags & HALF != 0) info.par_d *= 2;
    }
    abi.multiview_flags &= ~@as(c.GstVideoMultiviewFlags, HALF);
    abi.multiview_mode = out_mode;
    abi.multiview_flags = out_flags;
    if (wide(out_mode)) {
        info.width *= 2;
        info.views = @divTrunc(info.views, 2);
        if (out_flags & HALF != 0) info.par_d *= 2;
    } else if (tall(out_mode)) {
        info.height *= 2;
        info.views = @divTrunc(info.views, 2);
        if (out_flags & HALF != 0) info.par_n *= 2;
    }
}

pub export fn gst_video_multiview_guess_half_aspect(mode: Mode, width: c.guint, height: c.guint, par_n: c.guint, par_d: c.guint) c.gboolean {
    if (tall(mode)) return @intFromBool(height *% par_d <= width *% par_n);
    switch (mode) {
        c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE, c.GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX, c.GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED => {
            const lhs: f64 = @floatFromInt(width *% par_n);
            return @intFromBool(lhs < 2.39 * @as(f64, @floatFromInt(height)) * @as(f64, @floatFromInt(par_d)));
        },
        else => return 0,
    }
}
