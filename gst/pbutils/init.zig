const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("config");

comptime {
    @import("../abi.zig").check(@This());
}

pub const TEXT_DOMAIN = "gst-plugins-base-1.0";

var locale_once: std.atomic.Value(u32) = .init(0);
var inited = false;

pub fn tr(s: [*c]const u8) [*c]const u8 {
    return c.g_dgettext(TEXT_DOMAIN, s);
}

pub fn ensureLocale() void {
    if (locale_once.load(.acquire) == 2) return;
    if (locale_once.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        _ = c.bindtextdomain(TEXT_DOMAIN, config.locale_dir.ptr);
        _ = c.bind_textdomain_codeset(TEXT_DOMAIN, "UTF-8");
        locale_once.store(2, .release);
        return;
    }
    while (locale_once.load(.acquire) != 2) std.atomic.spinLoopHint();
}

pub export fn gst_pb_utils_init() void {
    if (inited) return;
    ensureLocale();
    inited = true;
}

pub export fn gst_plugins_base_version(major: [*c]c.guint, minor: [*c]c.guint, micro: [*c]c.guint, nano: [*c]c.guint) void {
    if (major != null) major[0] = c.GST_PLUGINS_BASE_VERSION_MAJOR;
    if (minor != null) minor[0] = c.GST_PLUGINS_BASE_VERSION_MINOR;
    if (micro != null) micro[0] = c.GST_PLUGINS_BASE_VERSION_MICRO;
    if (nano != null) nano[0] = c.GST_PLUGINS_BASE_VERSION_NANO;
}

pub export fn gst_plugins_base_version_string() [*c]c.gchar {
    const nano = c.GST_PLUGINS_BASE_VERSION_NANO;
    const tail: [*c]const u8 = if (nano == 0) "" else if (nano == 1) " (GIT)" else " (prerelease)";
    return c.g_strdup_printf("GStreamer Base Plugins %d.%d.%d%s", @as(c_int, c.GST_PLUGINS_BASE_VERSION_MAJOR), @as(c_int, c.GST_PLUGINS_BASE_VERSION_MINOR), @as(c_int, c.GST_PLUGINS_BASE_VERSION_MICRO), tail);
}
