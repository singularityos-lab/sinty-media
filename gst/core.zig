const std = @import("std");
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
    _ = @import("mini.zig");
    _ = @import("object.zig");
}

var ready = std.atomic.Value(bool).init(false);
var init_guard: c.GMutex = std.mem.zeroes(c.GMutex);

fn bringUp() void {
    @import("mini.zig").initialize();
    _ = c.g_type_class_ref(@import("object.zig").gst_object_get_type());
}

pub export fn gst_init_check(argc: [*c]c_int, argv: [*c][*c][*c]u8, err: [*c][*c]c.GError) c.gboolean {
    _ = argc;
    _ = argv;
    _ = err;
    c.g_mutex_lock(&init_guard);
    defer c.g_mutex_unlock(&init_guard);
    if (ready.load(.acquire)) return 1;
    bringUp();
    ready.store(true, .release);
    return 1;
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
