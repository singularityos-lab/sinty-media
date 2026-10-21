const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [65536]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn z(p: [*c]const u8) []const u8 {
    return if (p == null) "(null)" else std.mem.span(@as([*:0]const u8, @ptrCast(p)));
}

fn dumpType(t: c.GType) void {
    out("type {s} fundamental {s}", .{ z(c.g_type_name(t)), z(c.g_type_name(c.g_type_fundamental(t))) });
    const k = c.g_type_class_ref(t);
    if (c.g_type_fundamental(t) == c.G_TYPE_ENUM) {
        const ek: *c.GEnumClass = @ptrCast(@alignCast(k));
        for (0..ek.n_values) |i| out("  {d} {s} {s}", .{ ek.values[i].value, z(ek.values[i].value_name), z(ek.values[i].value_nick) });
        out("  min {d} max {d}", .{ ek.minimum, ek.maximum });
    } else {
        const fk: *c.GFlagsClass = @ptrCast(@alignCast(k));
        for (0..fk.n_values) |i| out("  {d} {s} {s}", .{ fk.values[i].value, z(fk.values[i].value_name), z(fk.values[i].value_nick) });
        out("  mask {d}", .{fk.mask});
    }
    c.g_type_class_unref(k);
}

var loop: ?*c.GMainLoop = null;

fn done(r: c.GstInstallPluginsReturn, data: c.gpointer) callconv(.c) void {
    out("  async result {d} {s} data {d} inprog {d}", .{ r, z(c.gst_install_plugins_return_get_name(r)), @intFromPtr(data), c.gst_install_plugins_installation_in_progress() });
    c.g_main_loop_quit(loop);
}

pub fn main() void {
    c.gst_init(null, null);
    dumpType(c.gst_install_plugins_return_get_type());
    dumpType(c.gst_discoverer_result_get_type());
    dumpType(c.gst_discoverer_serialize_flags_get_type());
    dumpType(c.gst_pb_utils_caps_description_flags_get_type());
    dumpType(c.gst_audio_visualizer_shader_get_type());
    var r: c_int = -2;
    while (r < 260) : (r += 1) {
        const n = c.gst_install_plugins_return_get_name(@bitCast(r));
        if (r < 6 or (r >= 99 and r <= 102) or (r >= 199 and r <= 204) or r == 259) out("ret {d} {s}", .{ r, z(n) });
    }
    const ct = c.gst_install_plugins_context_get_type();
    out("ctx type {s} boxed {d}", .{ z(c.g_type_name(ct)), @intFromBool(c.g_type_fundamental(ct) == c.G_TYPE_BOXED) });

    const cwd = c.g_get_current_dir();
    const path = c.g_build_filename(cwd, "zig-out", "pbhelper.sh", @as(?*anyopaque, null));
    const script = "#!/bin/sh\ncase \"$*\" in *quiet*) ;; *) echo \"helper:$*\";; esac\nfor a in \"$@\"; do case \"$a\" in exit=*) exit ${a#exit=};; crash) kill -SEGV $$;; esac; done\nexit 0\n";
    _ = c.g_file_set_contents(path, script, script.len, null);
    _ = c.chmod(path, 0o755);

    _ = c.g_setenv("GST_INSTALL_PLUGINS_HELPER", "/nonexistent/helper", 1);
    out("supported {d}", .{c.gst_install_plugins_supported()});
    const d1 = [_][*c]const u8{ "gstreamer|1.0|x|desc|decoder-foo", null };
    out("sync missing {d}", .{c.gst_install_plugins_sync(&d1, null)});
    out("async missing {d}", .{c.gst_install_plugins_async(&d1, null, done, null)});

    _ = c.g_setenv("GST_INSTALL_PLUGINS_HELPER", path, 1);
    out("supported {d} inprog {d}", .{ c.gst_install_plugins_supported(), c.gst_install_plugins_installation_in_progress() });
    const ctx = c.gst_install_plugins_context_new();
    c.gst_install_plugins_context_set_confirm_search(ctx, 1);
    c.gst_install_plugins_context_set_desktop_id(ctx, "org.test.App");
    c.gst_install_plugins_context_set_startup_notification_id(ctx, "sn-1");
    c.gst_install_plugins_context_set_xid(ctx, 77);
    const cp: ?*c.GstInstallPluginsContext = @ptrCast(c.g_boxed_copy(ct, ctx));
    c.gst_install_plugins_context_set_confirm_search(cp, 0);
    const cases = [_][3][*c]const u8{
        .{ "a", "b", null },
        .{ "a", "a", null },
        .{ "exit=1", "x", null },
        .{ "exit=3", null, null },
        .{ "exit=4", null, null },
        .{ "exit=5", null, null },
        .{ "exit=100", null, null },
        .{ "exit=150", null, null },
        .{ "exit=200", null, null },
        .{ "exit=201", null, null },
        .{ "exit=203", null, null },
        .{ "crash", null, null },
        .{ "--interaction=show-confirm-search", "z", null },
        .{ null, null, null },
    };
    for (cases) |cs| {
        out("sync ctx", .{});
        out("  -> {d}", .{c.gst_install_plugins_sync(&cs, ctx)});
        out("sync copy", .{});
        out("  -> {d}", .{c.gst_install_plugins_sync(&cs, cp)});
        out("sync none", .{});
        out("  -> {d}", .{c.gst_install_plugins_sync(&cs, null)});
    }
    loop = c.g_main_loop_new(null, 0);
    const da = [_][*c]const u8{ "quiet", "exit=2", null };
    out("async {d} inprog {d}", .{ c.gst_install_plugins_async(&da, ctx, done, @ptrFromInt(42)), c.gst_install_plugins_installation_in_progress() });
    out("async again {d}", .{c.gst_install_plugins_async(&da, ctx, done, null)});
    out("sync during {d}", .{c.gst_install_plugins_sync(&da, ctx)});
    c.g_main_loop_run(loop);
    const dc = [_][*c]const u8{ "quiet", "crash", null };
    out("async {d}", .{c.gst_install_plugins_async(&dc, null, done, @ptrFromInt(7))});
    c.g_main_loop_run(loop);
    out("checks", .{});
    out("  {d}", .{c.gst_install_plugins_sync(null, null)});
    out("  {d}", .{c.gst_install_plugins_async(null, null, done, null)});
    out("  {d}", .{c.gst_install_plugins_async(&da, null, null, null)});
    c.gst_install_plugins_context_set_confirm_search(null, 1);
    c.gst_install_plugins_context_set_desktop_id(null, "x");
    c.gst_install_plugins_context_set_startup_notification_id(null, "x");
    c.gst_install_plugins_context_set_xid(null, 1);
    c.gst_install_plugins_context_free(null);
    c.g_boxed_free(ct, cp);
    c.gst_install_plugins_context_free(ctx);
    _ = c.unlink(path);
}
