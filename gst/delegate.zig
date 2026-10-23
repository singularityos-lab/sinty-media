const std = @import("std");
const c = @import("c.zig").c;

extern fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;

const Unix = extern struct {
    family: u16,
    path: [108]u8,
};

var sinty: ?bool = null;

fn onSinty() bool {
    if (sinty) |v| return v;
    var contents: [*c]u8 = null;
    var found = false;
    if (c.g_file_get_contents("/etc/os-release", &contents, null, null) != 0) {
        var it = std.mem.splitScalar(u8, std.mem.span(contents), '\n');
        while (it.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "ID=sinty")) found = true;
        }
        c.g_free(contents);
    }
    sinty = found;
    return found;
}

fn enabled() bool {
    if (c.g_getenv("SINTY_MEDIA_DELEGATE")) |v| {
        if (v[0] == '0') return false;
        if (v[0] == '1') return true;
    }
    return onSinty();
}

fn socketPath(buf: []u8) ?[:0]const u8 {
    if (c.g_getenv("SINTY_MEDIAD_SOCKET")) |p| return std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(p)}) catch null;
    const dir = c.g_getenv("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/sinty-mediad.sock", .{std.mem.span(dir)}) catch null;
}

fn reachable() bool {
    var buf: [512]u8 = undefined;
    const path = socketPath(&buf) orelse return false;
    var addr = std.mem.zeroes(Unix);
    if (path.len >= addr.path.len) return false;
    addr.family = c.AF_UNIX;
    @memcpy(addr.path[0..path.len], path);
    const fd = c.socket(c.AF_UNIX, c.SOCK_SEQPACKET | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return connect(fd, &addr, @sizeOf(Unix)) == 0;
}

fn factoryName(e: *c.GstElement) []const u8 {
    const f = c.gst_element_get_factory(e) orelse return "";
    const n = @as(*c.GstObject, @ptrCast(@alignCast(f))).name;
    return if (n != null) std.mem.span(n) else "";
}

pub fn camera(e: [*c]c.GstElement, device_class: [*c]const u8) [*c]c.GstElement {
    if (e == null or device_class == null) return e;
    const cls = std.mem.span(device_class);
    if (std.mem.indexOf(u8, cls, "Video/Source") == null and std.mem.indexOf(u8, cls, "Source/Video") == null) return e;
    if (!std.mem.eql(u8, factoryName(e), "v4l2src")) return e;
    if (!enabled() or !reachable()) return e;
    var dev: [*c]u8 = null;
    c.g_object_get(e, "device", &dev, @as(?*anyopaque, null));
    if (dev == null) return e;
    defer c.g_free(dev);
    const quoted = c.g_shell_quote(dev);
    defer c.g_free(quoted);
    const desc = c.g_strdup_printf("v4l2src device=%s", quoted);
    defer c.g_free(desc);
    const name = c.gst_object_get_name(@ptrCast(e));
    defer c.g_free(name);
    const proxy = c.gst_element_factory_make("sintymediasrc", name) orelse return e;
    c.g_object_set(proxy, "source", desc, @as(?*anyopaque, null));
    _ = c.gst_object_ref_sink(e);
    c.gst_object_unref(e);
    return proxy;
}
