const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Mastering = c.GstVideoMasteringDisplayInfo;
const Light = c.GstVideoContentLightLevel;
const NONE = @as(?*anyopaque, null);

fn isCaps(caps: [*c]const c.GstCaps) bool {
    return caps != null and caps[0].mini_object.type == c.gst_caps_get_type();
}

fn parse(s: [*c]const u8, max: u64, v: *u64) bool {
    return c.g_ascii_string_to_unsigned(s, 10, 0, max, v, null) != 0;
}

pub export fn gst_video_mastering_display_info_init(m: [*c]Mastering) void {
    if (!check.that(m != null, "gst_video_mastering_display_info_init", "minfo != NULL")) return;
    m.* = std.mem.zeroes(Mastering);
}

pub export fn gst_video_mastering_display_info_from_string(m: [*c]Mastering, s: [*c]const u8) c.gboolean {
    const fname = "gst_video_mastering_display_info_from_string";
    if (!check.that(m != null, fname, "minfo != NULL")) return 0;
    if (!check.that(s != null, fname, "mastering != NULL")) return 0;
    const split = c.g_strsplit(s, ":", -1);
    defer c.g_strfreev(split);
    const ok = blk: {
        if (c.g_strv_length(split) != 10) break :blk false;
        var v: u64 = 0;
        for (0..3) |i| {
            if (!parse(split[i * 2], 0xffff, &v)) break :blk false;
            m[0].display_primaries[i].x = @truncate(v);
            if (!parse(split[i * 2 + 1], 0xffff, &v)) break :blk false;
            m[0].display_primaries[i].y = @truncate(v);
        }
        if (!parse(split[6], 0xffff, &v)) break :blk false;
        m[0].white_point.x = @truncate(v);
        if (!parse(split[7], 0xffff, &v)) break :blk false;
        m[0].white_point.y = @truncate(v);
        if (!parse(split[8], 0xffffffff, &v)) break :blk false;
        m[0].max_display_mastering_luminance = @truncate(v);
        if (!parse(split[9], 0xffffffff, &v)) break :blk false;
        m[0].min_display_mastering_luminance = @truncate(v);
        break :blk true;
    };
    if (!ok) gst_video_mastering_display_info_init(m);
    return @intFromBool(ok);
}

pub export fn gst_video_mastering_display_info_to_string(m: [*c]const Mastering) [*c]u8 {
    if (!check.that(m != null, "gst_video_mastering_display_info_to_string", "minfo != NULL")) return null;
    const p = m[0].display_primaries;
    const w = m[0].white_point;
    return c.g_strdup_printf("%d:%d:%d:%d:%d:%d:%d:%d:%d:%d", @as(c_int, p[0].x), @as(c_int, p[0].y), @as(c_int, p[1].x), @as(c_int, p[1].y), @as(c_int, p[2].x), @as(c_int, p[2].y), @as(c_int, w.x), @as(c_int, w.y), m[0].max_display_mastering_luminance, m[0].min_display_mastering_luminance);
}

pub export fn gst_video_mastering_display_info_is_equal(m: [*c]const Mastering, o: [*c]const Mastering) c.gboolean {
    const fname = "gst_video_mastering_display_info_is_equal";
    if (!check.that(m != null, fname, "minfo != NULL")) return 0;
    if (!check.that(o != null, fname, "other != NULL")) return 0;
    for (0..3) |i| {
        if (m[0].display_primaries[i].x != o[0].display_primaries[i].x or m[0].display_primaries[i].y != o[0].display_primaries[i].y) return 0;
    }
    return @intFromBool(m[0].white_point.x == o[0].white_point.x and m[0].white_point.y == o[0].white_point.y and m[0].max_display_mastering_luminance == o[0].max_display_mastering_luminance and m[0].min_display_mastering_luminance == o[0].min_display_mastering_luminance);
}

pub export fn gst_video_mastering_display_info_from_caps(m: [*c]Mastering, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_video_mastering_display_info_from_caps";
    if (!check.that(m != null, fname, "minfo != NULL")) return 0;
    if (!check.that(isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    const s = c.gst_structure_get_string(c.gst_caps_get_structure(caps, 0), "mastering-display-info");
    if (s == null) return 0;
    return gst_video_mastering_display_info_from_string(m, s);
}

pub export fn gst_video_mastering_display_info_add_to_caps(m: [*c]const Mastering, caps: [*c]c.GstCaps) c.gboolean {
    const fname = "gst_video_mastering_display_info_add_to_caps";
    if (!check.that(m != null, fname, "minfo != NULL")) return 0;
    if (!check.that(isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    if (!check.that(c.gst_mini_object_is_writable(@ptrCast(caps)) != 0, fname, "gst_caps_is_writable (caps)")) return 0;
    const s = gst_video_mastering_display_info_to_string(m);
    if (s == null) return 0;
    c.gst_caps_set_simple(caps, "mastering-display-info", c.G_TYPE_STRING, s, NONE);
    c.g_free(s);
    return 1;
}

pub export fn gst_video_content_light_level_init(l: [*c]Light) void {
    if (!check.that(l != null, "gst_video_content_light_level_init", "linfo != NULL")) return;
    l.* = std.mem.zeroes(Light);
}

pub export fn gst_video_content_light_level_from_string(l: [*c]Light, s: [*c]const u8) c.gboolean {
    const fname = "gst_video_content_light_level_from_string";
    if (!check.that(l != null, fname, "linfo != NULL")) return 0;
    if (!check.that(s != null, fname, "level != NULL")) return 0;
    const split = c.g_strsplit(s, ":", -1);
    defer c.g_strfreev(split);
    const ok = blk: {
        if (c.g_strv_length(split) != 2) break :blk false;
        var v: u64 = 0;
        if (!parse(split[0], 0xffff, &v)) break :blk false;
        l[0].max_content_light_level = @truncate(v);
        if (!parse(split[1], 0xffff, &v)) break :blk false;
        l[0].max_frame_average_light_level = @truncate(v);
        break :blk true;
    };
    if (!ok) gst_video_content_light_level_init(l);
    return @intFromBool(ok);
}

pub export fn gst_video_content_light_level_to_string(l: [*c]const Light) [*c]u8 {
    if (!check.that(l != null, "gst_video_content_light_level_to_string", "linfo != NULL")) return null;
    return c.g_strdup_printf("%d:%d", @as(c_int, l[0].max_content_light_level), @as(c_int, l[0].max_frame_average_light_level));
}

pub export fn gst_video_content_light_level_is_equal(l: [*c]const Light, o: [*c]const Light) c.gboolean {
    const fname = "gst_video_content_light_level_is_equal";
    if (!check.that(l != null, fname, "linfo != NULL")) return 0;
    if (!check.that(o != null, fname, "other != NULL")) return 0;
    return @intFromBool(l[0].max_content_light_level == o[0].max_content_light_level and l[0].max_frame_average_light_level == o[0].max_frame_average_light_level);
}

pub export fn gst_video_content_light_level_from_caps(l: [*c]Light, caps: [*c]const c.GstCaps) c.gboolean {
    const fname = "gst_video_content_light_level_from_caps";
    if (!check.that(l != null, fname, "linfo != NULL")) return 0;
    if (!check.that(isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    const s = c.gst_structure_get_string(c.gst_caps_get_structure(caps, 0), "content-light-level");
    if (s == null) return 0;
    return gst_video_content_light_level_from_string(l, s);
}

pub export fn gst_video_content_light_level_add_to_caps(l: [*c]const Light, caps: [*c]c.GstCaps) c.gboolean {
    const fname = "gst_video_content_light_level_add_to_caps";
    if (!check.that(l != null, fname, "linfo != NULL")) return 0;
    if (!check.that(isCaps(caps), fname, "GST_IS_CAPS (caps)")) return 0;
    if (!check.that(c.gst_mini_object_is_writable(@ptrCast(caps)) != 0, fname, "gst_caps_is_writable (caps)")) return 0;
    const s = gst_video_content_light_level_to_string(l);
    c.gst_caps_set_simple(caps, "content-light-level", c.G_TYPE_STRING, s, NONE);
    c.g_free(s);
    return 1;
}
