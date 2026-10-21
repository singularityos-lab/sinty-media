const c = @import("../c.zig").c;

pub const DOMAIN = "GStreamer-Base";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) fail(func, expr);
    return ok;
}

pub fn fail(comptime func: []const u8, comptime expr: []const u8) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
}
