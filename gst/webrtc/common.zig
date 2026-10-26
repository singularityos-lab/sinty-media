const c = @import("../c.zig").c;

pub const DOMAIN = "GStreamer-WebRTC";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

pub fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, comptime file: []const u8, line: c_int) void {
    c.g_log(DOMAIN, c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", @as([*c]const u8, file ++ ""), line, "property", id, spec.*.name, c.g_type_name(spec.*.g_type_instance.g_class.*.g_type), c.g_type_name(o.*.g_type_instance.g_class.*.g_type));
}

pub fn category(name: [*:0]const u8) void {
    _ = c._gst_debug_category_new(name, 0, name);
}

pub fn objectLock(o: anytype) void {
    c.g_mutex_lock(&@as(*c.GstObject, @ptrCast(@alignCast(o))).lock);
}

pub fn objectUnlock(o: anytype) void {
    c.g_mutex_unlock(&@as(*c.GstObject, @ptrCast(@alignCast(o))).lock);
}
