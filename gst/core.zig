const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
    _ = @import("mini.zig");
    _ = @import("object.zig");
    _ = @import("memory.zig");
    _ = @import("idstr.zig");
    _ = @import("util.zig");
    _ = @import("info.zig");
    _ = @import("value.zig");
    _ = @import("structure.zig");
    _ = @import("enumtypes.zig");
    _ = @import("capsfeatures.zig");
    _ = @import("caps.zig");
    _ = @import("iterator.zig");
    _ = @import("format.zig");
    _ = @import("datetime.zig");
    _ = @import("meta.zig");
    _ = @import("buffer.zig");
    _ = @import("bufferlist.zig");
    _ = @import("segment.zig");
    _ = @import("sample.zig");
    _ = @import("taglist.zig");
    _ = @import("context.zig");
    _ = @import("error.zig");
    _ = @import("toc.zig");
    _ = @import("streams.zig");
    _ = @import("streamcollection.zig");
    _ = @import("event.zig");
    _ = @import("message.zig");
    _ = @import("query.zig");
    _ = @import("vecdeque.zig");
    _ = @import("bufferpool.zig");
    _ = @import("clock.zig");
    _ = @import("sysclock.zig");
    _ = @import("poll.zig");
    _ = @import("bus.zig");
    _ = @import("task.zig");
}

var ready = std.atomic.Value(bool).init(false);
var init_guard: c.GRecMutex = std.mem.zeroes(c.GRecMutex);
var segtrap_off = false;

pub export var _gst_executable_path: [*c]u8 = null;
pub var start_time: c.GstClockTime = 0;
pub var plugin_paths: ?*c.GList = null;
pub var preload_plugins: ?*c.GSList = null;
pub var registry_disabled = false;
pub var registry_update_disabled = false;

fn forkSetEnabled() ?*const fn (c.gboolean) callconv(.c) void {
    return @import("gtype.zig").lookup(?*const fn (c.gboolean) callconv(.c) void, "gst_registry_fork_set_enabled");
}

fn findExecutablePath() void {
    if (_gst_executable_path != null) return;
    var buf: [4096]u8 = undefined;
    const n = c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return;
    _gst_executable_path = c.g_strndup(&buf, @intCast(n));
}

pub export fn gst_get_main_executable_path() [*c]const u8 {
    return _gst_executable_path;
}

fn pre(_: ?*c.GOptionContext, _: ?*c.GOptionGroup, _: c.gpointer, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    if (ready.load(.acquire)) return 1;
    findExecutablePath();
    start_time = @import("util.zig").gst_util_get_timestamp();
    @import("info.zig").initialize();
    if (c.g_getenv("GST_REGISTRY_DISABLE")) |v| registry_disabled = std.mem.orderZ(u8, v, "yes") == .eq;
    return 1;
}

fn post(_: ?*c.GOptionContext, _: ?*c.GOptionGroup, _: c.gpointer, _: [*c][*c]c.GError) callconv(.c) c.gboolean {
    if (ready.load(.acquire)) return 1;
    @import("mini.zig").initialize();
    @import("memory.zig").initialize();
    @import("format.zig").initialize();
    @import("value.zig").initialize();
    @import("structure.zig").initialize();
    @import("caps.zig").initialize();
    @import("capsfeatures.zig").initialize();
    @import("meta.zig").initialize();
    _ = c.g_type_class_ref(@import("object.zig").gst_object_get_type());
    _ = c.g_type_class_ref(c.gst_format_get_type());
    @import("buffer.zig").initialize();
    @import("bufferlist.zig").initialize();
    @import("segment.zig").initialize();
    @import("sample.zig").initialize();
    @import("datetime.zig").initialize();
    @import("context.zig").initialize();
    @import("taglist.zig").initialize();
    @import("toc.zig").initialize();
    @import("event.zig").initialize();
    @import("message.zig").initialize();
    @import("query.zig").initialize();
    ready.store(true, .release);
    return 1;
}

const Opt = enum(c_int) { none, version, fatal_warnings, debug_level, debug, debug_disable, debug_no_color, debug_color_mode, debug_help, plugin_path, plugin_load, segtrap_disable, registry_update_disable, registry_fork_disable };

const names = [_]struct { [:0]const u8, Opt }{
    .{ "--gst-version", .version },                    .{ "--gst-fatal-warnings", .fatal_warnings },
    .{ "--gst-debug-level", .debug_level },            .{ "--gst-debug", .debug },
    .{ "--gst-debug-disable", .debug_disable },        .{ "--gst-debug-no-color", .debug_no_color },
    .{ "--gst-debug-color-mode", .debug_color_mode },  .{ "--gst-debug-help", .debug_help },
    .{ "--gst-plugin-path", .plugin_path },            .{ "--gst-plugin-load", .plugin_load },
    .{ "--gst-disable-segtrap", .segtrap_disable },    .{ "--gst-disable-registry-update", .registry_update_disable },
    .{ "--gst-disable-registry-fork", .registry_fork_disable },
};

fn splitEach(list: [*c]const u8, sep: [*c]const u8, comptime each: fn ([*c]const u8) void) void {
    const parts = c.g_strsplit(list, sep, 0);
    defer c.g_strfreev(parts);
    var i: usize = 0;
    while (parts[i] != null) : (i += 1) each(parts[i]);
}

fn addPath(p: [*c]const u8) void {
    plugin_paths = c.g_list_append(plugin_paths, c.g_strdup(p));
}

fn addPreload(p: [*c]const u8) void {
    preload_plugins = c.g_slist_prepend(preload_plugins, c.g_strdup(p));
}

fn onOption(name: [*c]const u8, arg: [*c]const u8, _: c.gpointer, err: [*c][*c]c.GError) callconv(.c) c.gboolean {
    const info = @import("info.zig");
    var opt: Opt = .none;
    for (names) |n| if (std.mem.orderZ(u8, name, n[0]) == .eq) {
        opt = n[1];
        break;
    };
    switch (opt) {
        .version => {
            c.g_print("GStreamer Core Library version %s\n", "1.28.2");
            std.c.exit(0);
        },
        .fatal_warnings => {
            var mask = c.g_log_set_always_fatal(c.G_LOG_FATAL_MASK);
            mask |= c.G_LOG_LEVEL_WARNING | c.G_LOG_LEVEL_CRITICAL;
            _ = c.g_log_set_always_fatal(mask);
        },
        .debug_level => {
            const level: c_long = c.strtol(arg, null, 0);
            if (@as(c_ulong, @bitCast(level)) < c.GST_LEVEL_COUNT) info.gst_debug_set_default_threshold(@intCast(level));
        },
        .debug => info.gst_debug_set_threshold_from_string(arg, 0),
        .debug_no_color => info.gst_debug_set_colored(0),
        .debug_color_mode => info.gst_debug_set_color_mode_from_string(arg),
        .debug_disable => info.gst_debug_set_active(0),
        .debug_help => {
            _ = post(null, null, null, null);
            info.printHelp();
            std.c.exit(0);
        },
        .plugin_path => if (!registry_disabled) splitEach(arg, ":", addPath),
        .plugin_load => splitEach(arg, ",", addPreload),
        .segtrap_disable => segtrap_off = true,
        .registry_update_disable => if (!registry_disabled) {
            registry_update_disabled = true;
        },
        .registry_fork_disable => if (forkSetEnabled()) |f| f(0),
        .none => {
            c.g_set_error(err, c.g_option_error_quark(), c.G_OPTION_ERROR_UNKNOWN_OPTION, c.g_dgettext("gstreamer-1.0", "Unknown option"));
            return 0;
        },
    }
    return 1;
}

fn entry(comptime long: [:0]const u8, flags: c_int, comptime desc: [:0]const u8, comptime arg_desc: ?[:0]const u8) c.GOptionEntry {
    return .{ .long_name = long.ptr, .short_name = 0, .flags = flags, .arg = c.G_OPTION_ARG_CALLBACK, .arg_data = @constCast(@ptrCast(&onOption)), .description = desc.ptr, .arg_description = if (arg_desc) |a| a.ptr else null };
}

const NOARG = c.G_OPTION_FLAG_NO_ARG;

const entries = [_]c.GOptionEntry{
    entry("gst-version", NOARG, "Print the GStreamer version", null),
    entry("gst-fatal-warnings", NOARG, "Make all warnings fatal", null),
    entry("gst-debug-help", NOARG, "Print available debug categories and exit", null),
    entry("gst-debug-level", 0, "Default debug level from 1 (only error) to 9 (anything) or 0 for no output", "LEVEL"),
    entry("gst-debug", 0, "Comma-separated list of category_name:level pairs to set specific levels for the individual categories. Example: GST_AUTOPLUG:5,GST_ELEMENT_*:3", "LIST"),
    entry("gst-debug-no-color", NOARG, "Disable colored debugging output", null),
    entry("gst-debug-color-mode", 0, "Changes coloring mode of the debug log. Possible modes: off, on, disable, auto, unix", null),
    entry("gst-debug-disable", NOARG, "Disable debugging", null),
    entry("gst-plugin-path", 0, "Colon-separated paths containing plugins", "PATHS"),
    entry("gst-plugin-load", 0, "Comma-separated list of plugins to preload in addition to the list stored in environment variable GST_PLUGIN_PATH", "PLUGINS"),
    entry("gst-disable-segtrap", NOARG, "Disable trapping of segmentation faults during plugin loading", null),
    entry("gst-disable-registry-update", NOARG, "Disable updating the registry", null),
    entry("gst-disable-registry-fork", NOARG, "Disable spawning a helper process while scanning the registry", null),
    std.mem.zeroes(c.GOptionEntry),
};

pub export fn gst_init_get_option_group() ?*c.GOptionGroup {
    const group = c.g_option_group_new("gst", c.g_dgettext("gstreamer-1.0", "GStreamer Options"), c.g_dgettext("gstreamer-1.0", "Show GStreamer Options"), null, null);
    c.g_option_group_set_parse_hooks(group, @ptrCast(&pre), @ptrCast(&post));
    c.g_option_group_add_entries(group, &entries);
    c.g_option_group_set_translation_domain(group, "gstreamer-1.0");
    return group;
}

pub export fn gst_init_check(argc: [*c]c_int, argv: [*c][*c][*c]u8, err: [*c][*c]c.GError) c.gboolean {
    c.g_rec_mutex_lock(&init_guard);
    defer c.g_rec_mutex_unlock(&init_guard);
    if (ready.load(.acquire)) return 1;
    const ctx = c.g_option_context_new("- GStreamer initialization");
    c.g_option_context_set_ignore_unknown_options(ctx, 1);
    c.g_option_context_set_help_enabled(ctx, 0);
    c.g_option_context_add_group(ctx, gst_init_get_option_group());
    const ok = c.g_option_context_parse(ctx, argc, argv, err);
    c.g_option_context_free(ctx);
    if (ok == 0) ready.store(false, .release);
    return ok;
}

pub export fn gst_init(argc: [*c]c_int, argv: [*c][*c][*c]u8) void {
    var err: [*c]c.GError = null;
    if (gst_init_check(argc, argv, &err) == 0) {
        c.g_print("Could not initialize GStreamer: %s\n", @as([*c]const u8, if (err != null) err.*.message else "unknown error occurred"));
        if (err != null) c.g_error_free(err);
        std.c.exit(1);
    }
}

pub export fn gst_is_initialized() c.gboolean {
    return @intFromBool(ready.load(.acquire));
}

pub export fn gst_version(major: [*c]c.guint, minor: [*c]c.guint, micro: [*c]c.guint, nano: [*c]c.guint) void {
    if (!check.that(major != null, "gst_version", "major")) return;
    if (!check.that(minor != null, "gst_version", "minor")) return;
    if (!check.that(micro != null, "gst_version", "micro")) return;
    if (!check.that(nano != null, "gst_version", "nano")) return;
    major.* = 1;
    minor.* = 28;
    micro.* = 2;
    nano.* = 0;
}

pub export fn gst_version_string() [*c]u8 {
    return c.g_strdup_printf("GStreamer %d.%d.%d", @as(c_int, 1), @as(c_int, 28), @as(c_int, 2));
}

pub export fn gst_check_version(major: c.guint, minor: c.guint, micro: c.guint) c.gboolean {
    if (major != 1) return 0;
    if (minor > 28) return 0;
    if (minor < 28) return 1;
    return @intFromBool(micro <= 2);
}

pub export fn gst_segtrap_is_enabled() c.gboolean {
    return @intFromBool(!segtrap_off);
}

pub export fn gst_segtrap_set_enabled(enabled: c.gboolean) void {
    segtrap_off = enabled == 0;
}
