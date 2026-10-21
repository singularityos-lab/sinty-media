const std = @import("std");
const c = @import("c.zig").c;
const core = @import("core.zig");
const plugin = @import("plugin.zig");
const registry = @import("registry.zig");
const regcache = @import("regcache.zig");

const EXIT: u32 = 1;
const LOAD: u32 = 2;
const DETAILS: u32 = 4;
const VERSION: u32 = 5;
const MAX_PAYLOAD: u32 = 32 * 1024 * 1024;

pub const Loader = struct {
    reg: [*c]registry.Registry,
    running: bool = false,
    pid: c.GPid = 0,
    fd_w: c_int = -1,
    fd_r: c_int = -1,
    tag: u32 = 0,
    got_details: bool = false,
};

fn writeAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn readAll(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = c.read(fd, buf.ptr + off, buf.len - off);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn send(fd: c_int, kind: u32, tag: u32, payload: []const u8) bool {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], kind, .little);
    std.mem.writeInt(u32, hdr[4..8], tag, .little);
    std.mem.writeInt(u32, hdr[8..12], @intCast(payload.len), .little);
    return writeAll(fd, &hdr) and writeAll(fd, payload);
}

const Packet = struct {
    kind: u32,
    tag: u32,
    payload: []u8,

    fn free(p: Packet) void {
        c.g_free(p.payload.ptr);
    }
};

fn receive(fd: c_int) ?Packet {
    var hdr: [12]u8 = undefined;
    if (!readAll(fd, &hdr)) return null;
    const len = std.mem.readInt(u32, hdr[8..12], .little);
    if (len > MAX_PAYLOAD) return null;
    const buf: [*]u8 = @ptrCast(c.g_malloc(len + 1));
    buf[len] = 0;
    if (!readAll(fd, buf[0..len])) {
        c.g_free(buf);
        return null;
    }
    return .{ .kind = std.mem.readInt(u32, hdr[0..4], .little), .tag = std.mem.readInt(u32, hdr[4..8], .little), .payload = buf[0..len] };
}

fn versionPayload(w: *regcache.Writer) void {
    regcache.header(w);
}

fn scannerCandidates() [4][*c]u8 {
    var out = [4][*c]u8{ null, null, null, null };
    const env = c.g_getenv("GST_PLUGIN_SCANNER_1_0") orelse c.g_getenv("GST_PLUGIN_SCANNER");
    if (env != null and env[0] != 0) {
        out[0] = c.g_strdup(env);
        return out;
    }
    const lib = registry.libDir();
    defer c.g_free(lib);
    if (lib == null) {
        out[0] = c.g_strdup("/usr/libexec/gstreamer-1.0/gst-plugin-scanner");
        return out;
    }
    const none: [*c]const u8 = null;
    out[0] = c.g_build_filename(lib, "gstreamer1.0", "gstreamer-1.0", "gst-plugin-scanner", none);
    out[1] = c.g_build_filename(lib, "..", "libexec", "gstreamer-1.0", "gst-plugin-scanner", none);
    out[2] = c.g_build_filename(lib, "gstreamer-1.0", "gst-plugin-scanner", none);
    out[3] = c.g_strdup("/usr/libexec/gstreamer-1.0/gst-plugin-scanner");
    return out;
}

fn tryHelper(l: *Loader, location: [*c]u8) bool {
    var argv = [_][*c]u8{ location, @constCast("-l"), core.executablePath(), null };
    var err: [*c]c.GError = null;
    _ = c.g_spawn_async_with_pipes(null, @ptrCast(&argv), null, c.G_SPAWN_DO_NOT_REAP_CHILD, null, null, &l.pid, &l.fd_w, &l.fd_r, null, &err);
    if (err != null) {
        c.g_error_free(err);
        return false;
    }
    l.running = true;
    var mine = regcache.Writer.init();
    defer mine.deinit();
    versionPayload(&mine);
    if (!send(l.fd_w, VERSION, 0, &.{})) {
        cleanupChild(l);
        return false;
    }
    const reply = receive(l.fd_r) orelse {
        cleanupChild(l);
        return false;
    };
    defer reply.free();
    if (reply.kind != VERSION or !std.mem.eql(u8, reply.payload, mine.bytes())) {
        cleanupChild(l);
        return false;
    }
    return true;
}

fn spawn(l: *Loader) bool {
    if (l.running) return true;
    const cands = scannerCandidates();
    defer for (cands) |p| c.g_free(p);
    for (cands) |p| {
        if (p == null) continue;
        if (c.g_file_test(p, c.G_FILE_TEST_IS_EXECUTABLE) == 0) continue;
        if (tryHelper(l, p)) return true;
    }
    return false;
}

fn cleanupChild(l: *Loader) void {
    if (!l.running) return;
    _ = c.close(l.fd_w);
    _ = c.close(l.fd_r);
    _ = c.waitpid(l.pid, null, 0);
    c.g_spawn_close_pid(l.pid);
    l.running = false;
}

pub fn create(reg: [*c]registry.Registry) ?*Loader {
    const l: *Loader = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Loader))));
    l.* = .{ .reg = reg };
    if (!spawn(l)) {
        c.g_free(l);
        return null;
    }
    return l;
}

pub fn destroy(l: *Loader) bool {
    if (l.running) {
        if (send(l.fd_w, EXIT, 0, &.{})) {
            if (receive(l.fd_r)) |p| p.free();
        }
        cleanupChild(l);
    }
    const got = l.got_details;
    c.g_free(l);
    return got;
}

fn blacklist(l: *Loader, filename: [*c]const u8, size: c.off_t, mtime: c.time_t) void {
    const p = plugin.of(c.g_object_new(plugin.gst_plugin_get_type(), @as([*c]const u8, null)));
    p[0].filename = c.g_strdup(filename);
    p[0].file_mtime = mtime;
    p[0].file_size = size;
    p[0].object.flags |= c.GST_PLUGIN_FLAG_BLACKLISTED;
    p[0].basename = c.g_path_get_basename(filename);
    p[0].desc.name = c.g_intern_string(p[0].basename);
    p[0].desc.description = "Plugin for blacklisted file";
    p[0].desc.version = "0.0.0";
    p[0].desc.license = "BLACKLIST";
    p[0].desc.source = p[0].desc.license;
    p[0].desc.package = p[0].desc.license;
    p[0].desc.origin = p[0].desc.license;
    _ = registry.gst_registry_add_plugin(l.reg, p);
    l.got_details = true;
}

fn attempt(l: *Loader, filename: [*c]const u8) ?Packet {
    l.tag +%= 1;
    if (!send(l.fd_w, LOAD, l.tag, std.mem.span(filename)[0 .. std.mem.len(filename) + 1])) return null;
    const reply = receive(l.fd_r) orelse return null;
    if (reply.kind != DETAILS or reply.tag != l.tag) {
        reply.free();
        return null;
    }
    return reply;
}

pub fn load(l: *Loader, filename: [*c]const u8, size: c.off_t, mtime: c.time_t) bool {
    if (!spawn(l)) return false;
    const reply = attempt(l, filename) orelse retry: {
        cleanupChild(l);
        if (!spawn(l)) return false;
        break :retry attempt(l, filename) orelse {
            cleanupChild(l);
            blacklist(l, filename, size, mtime);
            return true;
        };
    };
    defer reply.free();
    if (reply.payload.len == 0) {
        blacklist(l, filename, size, mtime);
        return true;
    }
    var r = regcache.Reader{ .data = reply.payload };
    const p = regcache.loadPlugin(&r, l.reg) catch {
        cleanupChild(l);
        return false;
    };
    p[0].object.flags &= ~@as(c.guint32, c.GST_PLUGIN_FLAG_CACHED);
    p[0].registered = 1;
    l.got_details = true;
    return true;
}

fn forget(reg: [*c]registry.Registry, filename: [*c]const u8) void {
    const old = registry.gst_registry_lookup(reg, filename);
    if (old == null) return;
    defer c.gst_object_unref(old);
    if (old[0].module == null) registry.gst_registry_remove_plugin(reg, old);
}

fn serve(fd_r: c_int, fd_w: c_int) bool {
    const reg = registry.gst_registry_get();
    while (true) {
        const pkt = receive(fd_r) orelse return false;
        defer pkt.free();
        switch (pkt.kind) {
            VERSION => {
                var w = regcache.Writer.init();
                defer w.deinit();
                versionPayload(&w);
                if (!send(fd_w, VERSION, pkt.tag, w.bytes())) return false;
            },
            LOAD => {
                const name: [*c]const u8 = @ptrCast(pkt.payload.ptr);
                forget(reg, name);
                const p = plugin.gst_plugin_load_file(name, null);
                if (p == null) {
                    if (!send(fd_w, DETAILS, pkt.tag, &.{})) return false;
                    continue;
                }
                var w = regcache.Writer.init();
                defer w.deinit();
                regcache.savePlugin(&w, reg, p);
                c.gst_object_unref(p);
                if (!send(fd_w, DETAILS, pkt.tag, w.bytes())) return false;
            },
            EXIT => {
                _ = send(fd_w, EXIT, 0, &.{});
                return true;
            },
            else => return false,
        }
    }
}

pub export fn _gst_plugin_loader_client_run(_: [*c]const u8) c.gboolean {
    const fd_r = c.dup(0);
    if (fd_r == -1) return 0;
    _ = c.close(0);
    const fd_w = c.dup(1);
    if (fd_w == -1) return 0;
    _ = c.close(1);
    _ = c.dup2(2, 1);
    const ok = serve(fd_r, fd_w);
    _ = c.close(fd_r);
    _ = c.close(fd_w);
    return @intFromBool(ok);
}
