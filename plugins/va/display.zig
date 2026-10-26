const std = @import("std");
const v = @import("vc.zig").v;

pub const INVALID: u32 = 0xffffffff;
pub const SURFACES = 24;

pub const Display = struct {
    fd: c_int,
    dpy: v.VADisplay,

    pub fn open() ?Display {
        var name: [32]u8 = undefined;
        for (128..136) |n| {
            const path = std.fmt.bufPrintZ(&name, "/dev/dri/renderD{d}", .{n}) catch return null;
            const fd = v.open(path.ptr, v.O_RDWR | v.O_CLOEXEC);
            if (fd < 0) continue;
            const dpy = v.vaGetDisplayDRM(fd);
            if (dpy != null) {
                _ = v.vaSetErrorCallback(dpy, null, null);
                _ = v.vaSetInfoCallback(dpy, null, null);
                var major: c_int = 0;
                var minor: c_int = 0;
                if (v.vaInitialize(dpy, &major, &minor) == v.VA_STATUS_SUCCESS) return .{ .fd = fd, .dpy = dpy };
            }
            _ = v.close(fd);
        }
        return null;
    }

    pub fn close(d: *Display) void {
        _ = v.vaTerminate(d.dpy);
        _ = v.close(d.fd);
    }

    pub fn decodes(d: *const Display, profile: v.VAProfile) bool {
        var eps: [16]v.VAEntrypoint = undefined;
        var n: c_int = 0;
        if (v.vaQueryConfigEntrypoints(d.dpy, profile, &eps, &n) != v.VA_STATUS_SUCCESS) return false;
        for (eps[0..@intCast(@min(n, 16))]) |e| {
            if (e == v.VAEntrypointVLD) return true;
        }
        return false;
    }
};

pub fn probe(profile: v.VAProfile) bool {
    var d = Display.open() orelse return false;
    defer d.close();
    return d.decodes(profile);
}

pub const Session = struct {
    config: u32 = INVALID,
    context: u32 = INVALID,
    surfaces: [SURFACES]u32 = .{INVALID} ** SURFACES,
    count: usize = 0,
    pending: [160]v.VABufferID = undefined,
    pending_count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: c_uint = 0,

    pub fn ready(s: *const Session, width: u32, height: u32, format: c_uint) bool {
        return s.context != INVALID and s.width == width and s.height == height and s.format == format;
    }

    pub fn pool(s: *const Session) []const u32 {
        return s.surfaces[0..s.count];
    }

    pub fn create(s: *Session, d: *const Display, profile: v.VAProfile, width: u32, height: u32, format: c_uint, count: usize) bool {
        s.destroy(d);
        var attr = v.VAConfigAttrib{ .type = v.VAConfigAttribRTFormat, .value = format };
        if (v.vaCreateConfig(d.dpy, profile, v.VAEntrypointVLD, &attr, 1, &s.config) != v.VA_STATUS_SUCCESS) {
            s.config = INVALID;
            return false;
        }
        const n = @min(count, SURFACES);
        if (v.vaCreateSurfaces(d.dpy, format, width, height, &s.surfaces, @intCast(n), null, 0) != v.VA_STATUS_SUCCESS) {
            s.surfaces = .{INVALID} ** SURFACES;
            s.destroy(d);
            return false;
        }
        s.count = n;
        if (v.vaCreateContext(d.dpy, s.config, @intCast(width), @intCast(height), v.VA_PROGRESSIVE, &s.surfaces, @intCast(n), &s.context) != v.VA_STATUS_SUCCESS) {
            s.context = INVALID;
            s.destroy(d);
            return false;
        }
        s.width = width;
        s.height = height;
        s.format = format;
        return true;
    }

    pub fn destroy(s: *Session, d: *const Display) void {
        if (s.context != INVALID) _ = v.vaDestroyContext(d.dpy, s.context);
        if (s.count > 0) _ = v.vaDestroySurfaces(d.dpy, &s.surfaces, @intCast(s.count));
        if (s.config != INVALID) _ = v.vaDestroyConfig(d.dpy, s.config);
        s.* = .{};
    }

    pub fn begin(s: *Session, d: *const Display, target: u32) bool {
        s.pending_count = 0;
        return v.vaBeginPicture(d.dpy, s.context, target) == v.VA_STATUS_SUCCESS;
    }

    pub fn add(s: *Session, d: *const Display, kind: v.VABufferType, data: []const u8) bool {
        if (s.pending_count >= s.pending.len) return false;
        var id: v.VABufferID = undefined;
        if (v.vaCreateBuffer(d.dpy, s.context, kind, @intCast(data.len), 1, @constCast(data.ptr), &id) != v.VA_STATUS_SUCCESS) return false;
        s.pending[s.pending_count] = id;
        s.pending_count += 1;
        return v.vaRenderPicture(d.dpy, s.context, &id, 1) == v.VA_STATUS_SUCCESS;
    }

    pub fn end(s: *Session, d: *const Display) bool {
        const ok = v.vaEndPicture(d.dpy, s.context) == v.VA_STATUS_SUCCESS;
        for (s.pending[0..s.pending_count]) |id| _ = v.vaDestroyBuffer(d.dpy, id);
        s.pending_count = 0;
        return ok;
    }

    pub fn submit(s: *Session, d: *const Display, target: u32, buffers: []const Buffer) bool {
        if (!s.begin(d, target)) return false;
        var ok = true;
        for (buffers) |b| {
            if (!s.add(d, b.kind, b.data)) {
                ok = false;
                break;
            }
        }
        return s.end(d) and ok;
    }
};

pub const Buffer = struct {
    kind: v.VABufferType,
    data: []const u8,
};

pub fn bytesOf(p: anytype) []const u8 {
    return std.mem.asBytes(p);
}

pub const Plane = struct { data: [*]u8, stride: usize };

pub fn download(d: *const Display, surface: u32, fourcc: u32, x: u32, y: u32, width: u32, height: u32, planes: [2]Plane, bpp: usize) bool {
    if (v.vaSyncSurface(d.dpy, surface) != v.VA_STATUS_SUCCESS) return false;
    var img = std.mem.zeroes(v.VAImage);
    img.image_id = v.VA_INVALID_ID;
    if (v.vaDeriveImage(d.dpy, surface, &img) != v.VA_STATUS_SUCCESS or img.format.fourcc != fourcc) {
        if (img.image_id != v.VA_INVALID_ID) _ = v.vaDestroyImage(d.dpy, img.image_id);
        var fmt = std.mem.zeroes(v.VAImageFormat);
        fmt.fourcc = fourcc;
        fmt.byte_order = v.VA_LSB_FIRST;
        fmt.bits_per_pixel = @intCast(bpp * 12);
        if (v.vaCreateImage(d.dpy, &fmt, @intCast(x + width), @intCast(y + height), &img) != v.VA_STATUS_SUCCESS) return false;
        if (v.vaGetImage(d.dpy, surface, 0, 0, x + width, y + height, img.image_id) != v.VA_STATUS_SUCCESS) {
            _ = v.vaDestroyImage(d.dpy, img.image_id);
            return false;
        }
    }
    defer _ = v.vaDestroyImage(d.dpy, img.image_id);
    var raw: ?*anyopaque = null;
    if (v.vaMapBuffer(d.dpy, img.buf, &raw) != v.VA_STATUS_SUCCESS) return false;
    defer _ = v.vaUnmapBuffer(d.dpy, img.buf);
    const base: [*]const u8 = @ptrCast(raw.?);
    for (planes, 0..) |pl, i| {
        const rows = if (i == 0) height else (height + 1) / 2;
        const row = if (i == 0) width * bpp else ((width + 1) & ~@as(u32, 1)) * bpp;
        const sy = if (i == 0) y else y / 2;
        var src = base + img.offsets[i] + sy * img.pitches[i] + (x & ~@as(u32, 1)) * bpp;
        var dst = pl.data;
        for (0..rows) |_| {
            @memcpy(dst[0..row], src[0..row]);
            src += img.pitches[i];
            dst += pl.stride;
        }
    }
    return true;
}
