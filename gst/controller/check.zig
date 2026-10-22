const std = @import("std");
const c = @import("../c.zig").c;

pub const DOMAIN = "GStreamer-Controller";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

pub fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, comptime file: []const u8, line: c_int) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", @as([*c]const u8, file ++ ""), line, "property", id, spec.*.name, c.g_type_name(spec.*.g_type_instance.g_class.*.g_type), c.g_type_name(o.*.g_type_instance.g_class.*.g_type));
}

pub fn toU64(x: f64) u64 {
    const big: f64 = 9223372036854775808.0;
    if (x < big) return @bitCast(toI64(x));
    return @as(u64, @bitCast(toI64(x - big))) ^ (@as(u64, 1) << 63);
}

pub fn toI64(x: f64) i64 {
    if (!(x > -9223372036854775808.5 and x < 9223372036854775808.0)) return std.math.minInt(i64);
    return @intFromFloat(@trunc(x));
}

pub fn toI32(x: f64) i32 {
    if (!(x > -2147483649.0 and x < 2147483648.0)) return std.math.minInt(i32);
    return @intFromFloat(@trunc(x));
}
