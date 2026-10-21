const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub export fn gst_video_calculate_display_ratio(dar_n: [*c]c.guint, dar_d: [*c]c.guint, video_width: c.guint, video_height: c.guint, video_par_n: c.guint, video_par_d: c.guint, display_par_n: c.guint, display_par_d: c.guint) c.gboolean {
    const fname = "gst_video_calculate_display_ratio";
    if (!check.that(dar_n != null, fname, "dar_n != NULL")) return 0;
    if (!check.that(dar_d != null, fname, "dar_d != NULL")) return 0;
    var tn: c.gint = 0;
    var td: c.gint = 0;
    if (c.gst_util_fraction_multiply(@bitCast(video_width), @bitCast(video_height), @bitCast(video_par_n), @bitCast(video_par_d), &tn, &td) == 0) return 0;
    var n: c.gint = 0;
    var d: c.gint = 0;
    if (c.gst_util_fraction_multiply(tn, td, @bitCast(display_par_d), @bitCast(display_par_n), &n, &d) == 0) return 0;
    if (!check.that(n > 0, fname, "num > 0")) return 0;
    if (!check.that(d > 0, fname, "den > 0")) return 0;
    dar_n.* = @bitCast(n);
    dar_d.* = @bitCast(d);
    return 1;
}

pub export fn gst_video_guess_framerate(duration: c.GstClockTime, dest_n: [*c]c.gint, dest_d: [*c]c.gint) c.gboolean {
    if (duration == 0) return 0;
    const SECOND: u64 = c.GST_SECOND;
    var best_n: c.gint = undefined;
    var best_d: c.gint = undefined;
    if (duration > 100000) {
        best_n = @intCast(SECOND / 10000);
        best_d = @truncate(@as(i64, @bitCast(duration / 10000)));
    } else {
        best_n = @intCast(SECOND);
        best_d = @truncate(@as(i64, @bitCast(duration)));
    }
    var best_error: u64 = std.math.maxInt(u64);
    for ([_]c.gint{ 1, 2, 3, 4, 1001 }) |d| {
        var n: c.gint = @truncate(@as(i64, @bitCast(c.gst_util_uint64_scale_round(@intCast(d), SECOND, duration))));
        if (d == 1001) {
            n +%= 500;
            n -%= @rem(n, 1000);
        }
        if (n <= 0) continue;
        var a = c.gst_util_uint64_scale_int(SECOND, d, n);
        a = if (a < duration) duration - a else a - duration;
        if (a < 2) {
            if (dest_n != null) dest_n.* = n;
            if (dest_d != null) dest_d.* = d;
            return 1;
        }
        if (a *% 1000 < duration and a < best_error) {
            best_error = a;
            best_n = n;
            best_d = d;
        }
    }
    const gcd = c.gst_util_greatest_common_divisor(best_n, best_d);
    if (gcd != 0) {
        best_n = @divTrunc(best_n, gcd);
        best_d = @divTrunc(best_d, gcd);
    }
    if (dest_n != null) dest_n.* = best_n;
    if (dest_d != null) dest_d.* = best_d;
    return @intFromBool(best_error != std.math.maxInt(u64));
}

pub export fn gst_video_is_common_aspect_ratio(width: c.gint, height: c.gint, par_n: c.gint, par_d: c.gint) c.gboolean {
    var n: c.gint = 0;
    var d: c.gint = 0;
    _ = c.gst_util_fraction_multiply(width, height, par_n, par_d, &n, &d);
    for ([_][2]c.gint{ .{ 16, 9 }, .{ 4, 3 }, .{ 14, 9 }, .{ 8, 5 }, .{ 21, 11 } }) |r| {
        if (n == r[0] and d == r[1]) return 1;
    }
    return 0;
}

pub export fn gst_video_alignment_reset(al: [*c]c.GstVideoAlignment) void {
    if (!check.that(al != null, "gst_video_alignment_reset", "align != NULL")) return;
    al[0].padding_top = 0;
    al[0].padding_bottom = 0;
    al[0].padding_left = 0;
    al[0].padding_right = 0;
    al[0].stride_align = .{ 0, 0, 0, 0 };
}

const orientations = [_]struct { [*:0]const u8, c.GstVideoOrientationMethod }{
    .{ "rotate-0", c.GST_VIDEO_ORIENTATION_IDENTITY },
    .{ "rotate-90", c.GST_VIDEO_ORIENTATION_90R },
    .{ "rotate-180", c.GST_VIDEO_ORIENTATION_180 },
    .{ "rotate-270", c.GST_VIDEO_ORIENTATION_90L },
    .{ "flip-rotate-0", c.GST_VIDEO_ORIENTATION_HORIZ },
    .{ "flip-rotate-90", c.GST_VIDEO_ORIENTATION_UR_LL },
    .{ "flip-rotate-180", c.GST_VIDEO_ORIENTATION_VERT },
    .{ "flip-rotate-270", c.GST_VIDEO_ORIENTATION_UL_LR },
};

pub export fn gst_video_orientation_from_tag(taglist: [*c]c.GstTagList, method: [*c]c.GstVideoOrientationMethod) c.gboolean {
    const fname = "gst_video_orientation_from_tag";
    if (!check.that(taglist != null and taglist[0].mini_object.type == c.gst_tag_list_get_type(), fname, "GST_IS_TAG_LIST (taglist)")) return 0;
    if (!check.that(method != null, fname, "method != NULL")) return 0;
    var o: [*c]u8 = null;
    if (c.gst_tag_list_get_string(taglist, "image-orientation", &o) == 0) return 0;
    defer c.g_free(o);
    for (orientations) |e| {
        if (c.g_strcmp0(e[0], o) == 0) {
            method.* = e[1];
            return 1;
        }
    }
    return 0;
}
