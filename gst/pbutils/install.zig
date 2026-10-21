const std = @import("std");
const c = @import("../c.zig").c;
const config = @import("config");
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Ret = c.GstInstallPluginsReturn;

const Context = struct {
    confirm_search: [*c]u8 = null,
    desktop_id: [*c]u8 = null,
    startup_notification_id: [*c]u8 = null,
    xid: c.guint = 0,
};

fn ctxOf(p: ?*c.GstInstallPluginsContext) *Context {
    return @ptrCast(@alignCast(p));
}

var in_progress: c.gboolean = 0;
var ctx_once: gtype.Once = .{};

pub export fn gst_install_plugins_context_set_confirm_search(ctx: ?*c.GstInstallPluginsContext, confirm_search: c.gboolean) void {
    if (!check.that(ctx != null, "gst_install_plugins_context_set_confirm_search", "ctx != NULL")) return;
    ctxOf(ctx).confirm_search = c.g_strdup(if (confirm_search != 0) "show-confirm-search" else "hide-confirm-search");
}

pub export fn gst_install_plugins_context_set_desktop_id(ctx: ?*c.GstInstallPluginsContext, desktop_id: [*c]const c.gchar) void {
    if (!check.that(ctx != null, "gst_install_plugins_context_set_desktop_id", "ctx != NULL")) return;
    ctxOf(ctx).desktop_id = c.g_strdup(desktop_id);
}

pub export fn gst_install_plugins_context_set_startup_notification_id(ctx: ?*c.GstInstallPluginsContext, startup_id: [*c]const c.gchar) void {
    if (!check.that(ctx != null, "gst_install_plugins_context_set_startup_notification_id", "ctx != NULL")) return;
    ctxOf(ctx).startup_notification_id = c.g_strdup(startup_id);
}

pub export fn gst_install_plugins_context_set_xid(ctx: ?*c.GstInstallPluginsContext, xid: c.guint) void {
    if (!check.that(ctx != null, "gst_install_plugins_context_set_xid", "ctx != NULL")) return;
    ctxOf(ctx).xid = xid;
}

pub export fn gst_install_plugins_context_new() ?*c.GstInstallPluginsContext {
    return @ptrCast(c.g_malloc0(@sizeOf(Context)));
}

pub export fn gst_install_plugins_context_free(ctx: ?*c.GstInstallPluginsContext) void {
    if (!check.that(ctx != null, "gst_install_plugins_context_free", "ctx != NULL")) return;
    const x = ctxOf(ctx);
    c.g_free(x.confirm_search);
    c.g_free(x.desktop_id);
    c.g_free(x.startup_notification_id);
    c.g_free(ctx);
}

pub export fn gst_install_plugins_context_copy(ctx: ?*c.GstInstallPluginsContext) ?*c.GstInstallPluginsContext {
    const r = gst_install_plugins_context_new();
    const s = ctxOf(ctx);
    const d = ctxOf(r);
    d.confirm_search = c.g_strdup(s.confirm_search);
    d.desktop_id = c.g_strdup(s.desktop_id);
    d.startup_notification_id = c.g_strdup(s.startup_notification_id);
    d.xid = s.xid;
    return r;
}

fn boxCopy(p: c.gpointer) callconv(.c) c.gpointer {
    return gst_install_plugins_context_copy(@ptrCast(p));
}

fn boxFree(p: c.gpointer) callconv(.c) void {
    gst_install_plugins_context_free(@ptrCast(p));
}

pub export fn gst_install_plugins_context_get_type() c.GType {
    return ctx_once.get(struct {
        fn f() c.GType {
            return gtype.boxed("GstInstallPluginsContext", boxCopy, boxFree);
        }
    }.f);
}

fn helper() [*c]const u8 {
    const h = c.g_getenv("GST_INSTALL_PLUGINS_HELPER");
    return if (h != null) h else config.install_helper.ptr;
}

fn hasString(arr: *c.GPtrArray, s: [*c]const u8) bool {
    for (0..arr.len) |i| {
        if (c.strcmp(@ptrCast(arr.pdata[i]), s) == 0) return true;
    }
    return false;
}

fn spawn(details: [*c]const [*c]const c.gchar, ctx: ?*c.GstInstallPluginsContext, pid: ?*c.GPid, status: ?*c.gint) bool {
    const arr: *c.GPtrArray = c.g_ptr_array_new_with_free_func(c.g_free);
    defer c.g_ptr_array_unref(arr);
    c.g_ptr_array_add(arr, c.g_strdup(helper()));
    if (ctx != null) {
        const x = ctxOf(ctx);
        if (x.confirm_search != null) c.g_ptr_array_add(arr, c.g_strdup_printf("--interaction=%s", x.confirm_search));
        if (x.desktop_id != null) c.g_ptr_array_add(arr, c.g_strdup_printf("--desktop-id=%s", x.desktop_id));
        if (x.startup_notification_id != null) c.g_ptr_array_add(arr, c.g_strdup_printf("--startup-notification-id=%s", x.startup_notification_id));
        if (x.xid != 0) c.g_ptr_array_add(arr, c.g_strdup_printf("--transient-for=%u", x.xid));
    }
    var d = details;
    while (d != null and d[0] != null) : (d += 1) {
        if (!hasString(arr, d[0])) c.g_ptr_array_add(arr, c.g_strdup(d[0]));
    }
    c.g_ptr_array_add(arr, null);
    const argv: [*c][*c]c.gchar = @ptrCast(arr.pdata);
    var err: [*c]c.GError = null;
    var ok: c.gboolean = 0;
    if (pid == null and status != null) {
        in_progress = 1;
        ok = c.g_spawn_sync(null, argv, null, 0, null, null, null, null, status, &err);
        in_progress = 0;
    } else if (pid != null and status == null) {
        in_progress = 1;
        ok = c.g_spawn_async(null, argv, null, c.G_SPAWN_DO_NOT_REAP_CHILD, null, null, pid, &err);
    } else {
        check.reached("install-plugins.c", 572, "gst_install_plugins_spawn_child");
        return false;
    }
    if (ok == 0) c.g_error_free(err);
    return ok != 0;
}

fn fromStatus(status: c.gint) Ret {
    const s: c.guint = @bitCast(status);
    if (s & 0x7f != 0) return c.GST_INSTALL_PLUGINS_CRASHED;
    const r: c.guint = (s & 0xff00) >> 8;
    if (r >= c.GST_INSTALL_PLUGINS_STARTED_OK and r != c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE) return c.GST_INSTALL_PLUGINS_INVALID;
    return @intCast(r);
}

const Pending = struct {
    func: c.GstInstallPluginsResultFunc,
    data: c.gpointer,
};

fn exited(_: c.GPid, status: c.gint, data: c.gpointer) callconv(.c) void {
    in_progress = 0;
    const p: *Pending = @ptrCast(@alignCast(data));
    p.func.?(fromStatus(status), p.data);
    c.g_free(p);
}

pub export fn gst_install_plugins_async(details: [*c]const [*c]const c.gchar, ctx: ?*c.GstInstallPluginsContext, func: c.GstInstallPluginsResultFunc, user_data: c.gpointer) Ret {
    if (!check.that(details != null, "gst_install_plugins_async", "details != NULL")) return c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE;
    if (!check.that(func != null, "gst_install_plugins_async", "func != NULL")) return c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE;
    if (in_progress != 0) return c.GST_INSTALL_PLUGINS_INSTALL_IN_PROGRESS;
    if (c.g_file_test(helper(), c.G_FILE_TEST_IS_EXECUTABLE) == 0) return c.GST_INSTALL_PLUGINS_HELPER_MISSING;
    var pid: c.GPid = 0;
    if (!spawn(details, ctx, &pid, null)) return c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE;
    const p: *Pending = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Pending))));
    p.* = .{ .func = func, .data = user_data };
    _ = c.g_child_watch_add(pid, exited, p);
    return c.GST_INSTALL_PLUGINS_STARTED_OK;
}

pub export fn gst_install_plugins_sync(details: [*c]const [*c]const c.gchar, ctx: ?*c.GstInstallPluginsContext) Ret {
    if (!check.that(details != null, "gst_install_plugins_sync", "details != NULL")) return c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE;
    if (in_progress != 0) return c.GST_INSTALL_PLUGINS_INSTALL_IN_PROGRESS;
    if (c.g_file_test(helper(), c.G_FILE_TEST_IS_EXECUTABLE) == 0) return c.GST_INSTALL_PLUGINS_HELPER_MISSING;
    var status: c.gint = 0;
    if (!spawn(details, ctx, null, &status)) return c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE;
    return fromStatus(status);
}

pub export fn gst_install_plugins_return_get_name(ret: Ret) [*c]const c.gchar {
    return switch (ret) {
        c.GST_INSTALL_PLUGINS_SUCCESS => "success",
        c.GST_INSTALL_PLUGINS_NOT_FOUND => "not-found",
        c.GST_INSTALL_PLUGINS_ERROR => "install-error",
        c.GST_INSTALL_PLUGINS_CRASHED => "installer-exit-unclean",
        c.GST_INSTALL_PLUGINS_PARTIAL_SUCCESS => "partial-success",
        c.GST_INSTALL_PLUGINS_USER_ABORT => "user-abort",
        c.GST_INSTALL_PLUGINS_STARTED_OK => "started-ok",
        c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE => "internal-failure",
        c.GST_INSTALL_PLUGINS_HELPER_MISSING => "helper-missing",
        c.GST_INSTALL_PLUGINS_INSTALL_IN_PROGRESS => "install-in-progress",
        c.GST_INSTALL_PLUGINS_INVALID => "invalid",
        else => "(UNKNOWN)",
    };
}

pub export fn gst_install_plugins_installation_in_progress() c.gboolean {
    return in_progress;
}

pub export fn gst_install_plugins_supported() c.gboolean {
    return c.g_file_test(helper(), c.G_FILE_TEST_IS_EXECUTABLE);
}
