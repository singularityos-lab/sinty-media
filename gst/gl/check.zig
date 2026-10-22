const c = @import("../c.zig").c;

pub const DOMAIN = "GStreamer-GL";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

pub fn reached(comptime file: []const u8, line: c_int, comptime func: []const u8) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", @as([*c]const u8, "../gst-libs/gst/gl/" ++ file), line, @as([*c]const u8, func ++ ""));
}

pub fn assertFail(comptime file: []const u8, line: c_int, comptime func: []const u8, comptime expr: ?[*:0]const u8) noreturn {
    c.g_assertion_message_expr(DOMAIN, "../gst-libs/gst/gl/" ++ file, line, @as([*c]const u8, func ++ ""), expr);
    unreachable;
}

pub fn elementMessage(el: anytype, kind: c.GstMessageType, domain: c.GQuark, code: c.gint, text: [*c]u8, debug: [*c]u8, comptime file: []const u8, comptime func: []const u8, line: c.gint) void {
    c.gst_element_message_full(@ptrCast(@alignCast(el)), kind, domain, code, text, debug, "../gst-libs/gst/gl/" ++ file, func ++ "", line);
}
