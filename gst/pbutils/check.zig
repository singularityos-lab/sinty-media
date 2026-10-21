const c = @import("../c.zig").c;

pub const DOMAIN = "GStreamer-PBUtils";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) fail(func, expr);
    return ok;
}

pub fn fail(comptime func: []const u8, comptime expr: []const u8) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
}

pub fn reached(comptime file: []const u8, line: c_int, comptime func: []const u8) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", @as([*c]const u8, "../gst-libs/gst/pbutils/" ++ file), line, @as([*c]const u8, func ++ ""));
}

pub fn isCaps(p: anytype) bool {
    const m: [*c]const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m[0].type == c.gst_caps_get_type();
}

pub fn isMessage(p: anytype) bool {
    const m: [*c]const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m[0].type == c.gst_message_get_type();
}

pub fn isTagList(p: anytype) bool {
    const m: [*c]const c.GstMiniObject = @ptrCast(@alignCast(p));
    return m != null and m[0].type == c.gst_tag_list_get_type();
}

pub fn isElement(p: anytype) bool {
    return p != null and c.g_type_check_instance_is_a(@ptrCast(@alignCast(p)), c.gst_element_get_type()) != 0;
}
