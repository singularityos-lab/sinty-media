const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const el = @import("../base/el.zig");
const dmabuf = @import("dmabuf.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const linux = std.os.linux;
const PATH = "../gst-libs/gst/allocators/gstdrmdumb.c";
const MEMORY_TYPE = "DRMDumbMemory";

extern fn drmIoctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) c_int;
extern fn drmGetCap(fd: c_int, capability: u64, value: *u64) c_int;
extern fn drmGetDeviceNameFromFd2(fd: c_int) [*c]u8;
extern fn drmPrimeHandleToFD(fd: c_int, handle: u32, flags: u32, prime_fd: *c_int) c_int;

const CreateDumb = extern struct { height: u32 = 0, width: u32 = 0, bpp: u32 = 0, flags: u32 = 0, handle: u32 = 0, pitch: u32 = 0, size: u64 = 0 };
const MapDumb = extern struct { handle: u32 = 0, pad: u32 = 0, offset: u64 = 0 };
const DestroyDumb = extern struct { handle: u32 = 0 };

const IOCTL_CREATE = linux.IOCTL.IOWR('d', 0xB2, CreateDumb);
const IOCTL_MAP = linux.IOCTL.IOWR('d', 0xB3, MapDumb);
const IOCTL_DESTROY = linux.IOCTL.IOWR('d', 0xB4, DestroyDumb);
const CAP_DUMB_BUFFER: u64 = 0x1;
const CAP_PRIME: u64 = 0x5;
const PRIME_CAP_EXPORT: u64 = 0x2;
const DRM_CLOEXEC: u32 = 0o2000000;
const DRM_RDWR: u32 = 0o2;

const DumbMemory = extern struct {
    parent: Memory,
    ptr: ?*anyopaque,
    size: usize,
    handle: u32,
    refs: c.guint,
};

const Dumb = extern struct {
    parent: Allocator,
    drm_fd: c.gint,
    drm_device_path: [*c]u8,
    dmabuf_alloc: [*c]Allocator,
};

const DumbClass = extern struct {
    parent: c.GstAllocatorClass,
};

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;
var props: [3]?*c.GParamSpec = .{ null, null, null };

fn dumb(a: anytype) *Dumb {
    return @ptrCast(@alignCast(a));
}

fn fourcc(s: *const [4:0]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

fn heightFor(fmt: u32, h: u32) u32 {
    if (fmt == fourcc("YU12") or fmt == fourcc("YV12") or fmt == fourcc("YU16") or fmt == fourcc("NV12") or fmt == fourcc("NV21") or fmt == fourcc("NV15") or fmt == fourcc("P010") or fmt == fourcc("P016")) return h * 3 / 2;
    if (fmt == fourcc("NV16") or fmt == fourcc("NV61")) return h * 2;
    if (fmt == fourcc("NV24")) return h * 3;
    return h;
}

fn bppFor(fmt: u32) u32 {
    for ([_]*const [4:0]u8{ "YU12", "YV12", "YU16", "NV12", "NV21", "NV16", "NV61", "NV24" }) |f| if (fmt == fourcc(f)) return 8;
    if (fmt == fourcc("NV15")) return 10;
    for ([_]*const [4:0]u8{ "P010", "UYVY", "YUYV", "YVYU", "P016", "RG16", "BG16" }) |f| if (fmt == fourcc(f)) return 16;
    if (fmt == fourcc("BG24") or fmt == fourcc("RG24")) return 24;
    return 32;
}

pub export fn gst_is_drm_dumb_memory(mem: [*c]Memory) c.gboolean {
    return c.gst_memory_is_type(mem, MEMORY_TYPE);
}

pub export fn gst_drm_dumb_memory_get_handle(mem: [*c]Memory) c.guint32 {
    if (gst_is_drm_dumb_memory(mem) == 0) return 0;
    return @as(*DumbMemory, @ptrCast(@alignCast(mem))).handle;
}

pub export fn gst_drm_dumb_memory_export_dmabuf(mem: [*c]Memory) [*c]Memory {
    const m: *DumbMemory = @ptrCast(@alignCast(mem));
    const a = dumb(mem[0].allocator);
    var prime: c_int = 0;
    if (drmPrimeHandleToFD(a.drm_fd, m.handle, DRM_CLOEXEC | DRM_RDWR, &prime) != 0) return null;
    return dmabuf.gst_dmabuf_allocator_alloc_with_flags(a.dmabuf_alloc, prime, c.gst_memory_get_sizes(mem, null, null), c.GST_FD_MEMORY_FLAG_KEEP_MAPPED);
}

fn openDevice(a: *Dumb, path: [*c]const u8) void {
    if (path == null) return;
    if (a.drm_fd != -1) c.g_assertion_message_expr(check.DOMAIN, PATH, 273, "gst_drm_dumb_allocator_open_device", "alloc->drm_fd == -1");
    if (a.drm_device_path != null) c.g_assertion_message_expr(check.DOMAIN, PATH, 274, "gst_drm_dumb_allocator_open_device", "alloc->drm_device_path == NULL");
    const f = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    if (f < 0) return;
    a.drm_device_path = c.g_strdup(path);
    a.drm_fd = f;
}

fn setFd(a: *Dumb, f: c_int) void {
    if (f == -1) return;
    if (a.drm_fd != -1) c.g_assertion_message_expr(check.DOMAIN, PATH, 297, "gst_drm_dumb_allocator_set_fd", "alloc->drm_fd == -1");
    if (a.drm_device_path != null) c.g_assertion_message_expr(check.DOMAIN, PATH, 298, "gst_drm_dumb_allocator_set_fd", "alloc->drm_device_path == NULL");
    if (f >= 0) {
        a.drm_device_path = drmGetDeviceNameFromFd2(f);
        if (a.drm_device_path == null) return;
        a.drm_fd = std.c.dup(f);
    }
}

fn reset(a: *Dumb, m: *DumbMemory) void {
    if (m.size == 0 or a.drm_fd < 0) return;
    if (m.ptr) |p| {
        _ = linux.munmap(@ptrCast(@alignCast(p)), m.size);
        m.ptr = null;
    }
    var arg = DestroyDumb{ .handle = m.handle };
    _ = drmIoctl(a.drm_fd, IOCTL_DESTROY, &arg);
    m.handle = std.math.maxInt(u32);
    m.size = 0;
}

fn create(a: *Dumb, m: *DumbMemory, fmt: u32, w: u32, h: u32, pitch: [*c]u32) bool {
    if (m.size != 0) return true;
    if (a.drm_fd < 0) return false;
    var arg = CreateDumb{ .bpp = bppFor(fmt), .width = w, .height = heightFor(fmt, h) };
    if (drmIoctl(a.drm_fd, IOCTL_CREATE, &arg) != 0) return false;
    if (arg.pitch != 0) pitch[0] = arg.pitch;
    m.handle = arg.handle;
    m.size = @intCast(arg.size);
    return true;
}

fn free(alloc: [*c]Allocator, mem: [*c]Memory) callconv(.c) void {
    const m: *DumbMemory = @ptrCast(@alignCast(mem));
    reset(dumb(alloc), m);
    c.g_free(m);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => setFd(dumb(o), c.g_value_get_int(v)),
        2 => openDevice(dumb(o), c.g_value_get_string(v)),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 427),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, pspec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => c.g_value_set_int(v, dumb(o).drm_fd),
        2 => c.g_value_set_string(v, dumb(o).drm_device_path),
        else => el.badPropertyAt(o, id, pspec, check.DOMAIN, PATH, 446),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const a = dumb(o);
    c.gst_object_unref(a.dmabuf_alloc);
    c.g_free(a.drm_device_path);
    a.drm_device_path = null;
    if (a.drm_fd >= 0) {
        _ = std.c.close(a.drm_fd);
        a.drm_fd = -1;
    }
    parent.?.finalize.?(o);
}

fn memMap(mem: [*c]Memory, _: usize, _: c.GstMapFlags) callconv(.c) c.gpointer {
    const a = dumb(mem[0].allocator);
    if (a.drm_fd < 0) return null;
    const m: *DumbMemory = @ptrCast(@alignCast(mem));
    if (m.size == 0) return null;
    if (m.ptr == null) {
        var arg = MapDumb{ .handle = m.handle };
        if (drmIoctl(a.drm_fd, IOCTL_MAP, &arg) != 0) return null;
        const r = linux.mmap(null, m.size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, a.drm_fd, @intCast(arg.offset));
        if (linux.errno(r) != .SUCCESS) return null;
        m.ptr = @ptrFromInt(r);
    }
    _ = @atomicRmw(c.guint, &m.refs, .Add, 1, .seq_cst);
    return m.ptr;
}

fn memUnmap(mem: [*c]Memory) callconv(.c) void {
    if (dumb(mem[0].allocator).drm_fd < 0) return;
    const m: *DumbMemory = @ptrCast(@alignCast(mem));
    if (m.size == 0) return;
    if (@atomicRmw(c.guint, &m.refs, .Sub, 1, .seq_cst) == 1) {
        _ = linux.munmap(@ptrCast(@alignCast(m.ptr)), m.size);
        m.ptr = null;
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    ac.free = free;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const flags = c.G_PARAM_READWRITE | c.G_PARAM_STATIC_STRINGS | c.G_PARAM_CONSTRUCT_ONLY;
    props[1] = c.g_param_spec_int("drm-fd", "DRM fd", "DRM file descriptor", -1, std.math.maxInt(c.gint), -1, flags);
    props[2] = c.g_param_spec_string("drm-device-path", "DRM device path", "DRM device path", null, flags);
    c.g_object_class_install_properties(oc, 3, &props);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a = dumb(inst);
    a.drm_fd = -1;
    a.drm_device_path = null;
    a.dmabuf_alloc = dmabuf.gst_dmabuf_allocator_new();
    a.parent.mem_type = MEMORY_TYPE;
    a.parent.mem_map = memMap;
    a.parent.mem_unmap = memUnmap;
    a.parent.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_drm_dumb_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_allocator_get_type, "GstDRMDumbAllocator", DumbClass, Dumb, classInit, init, 0);
            _ = c._gst_debug_category_new("drmdumballocator", 0, "DRM dumb buffer allocator");
            return t;
        }
    }.f);
}

fn hasCap(a: ?*Dumb) bool {
    const x = a orelse return false;
    if (x.drm_fd < 0) return false;
    var v: u64 = 0;
    _ = drmGetCap(x.drm_fd, CAP_DUMB_BUFFER, &v);
    return v != 0;
}

fn finish(obj: c.gpointer) [*c]Allocator {
    _ = c.gst_object_ref_sink(obj);
    var a: ?*Dumb = dumb(obj);
    if (a.?.drm_fd < 0) {
        c.g_object_unref(a);
        a = null;
    }
    if (!hasCap(a)) {
        if (a != null) c.g_object_unref(a);
        a = null;
    }
    return if (a) |x| @ptrCast(x) else null;
}

pub export fn gst_drm_dumb_allocator_new_with_fd(drm_fd: c.gint) [*c]Allocator {
    return finish(c.g_object_new(gst_drm_dumb_allocator_get_type(), "drm-fd", drm_fd, @as(?*anyopaque, null)));
}

pub export fn gst_drm_dumb_allocator_new_with_device_path(path: [*c]const c.gchar) [*c]Allocator {
    return finish(c.g_object_new(gst_drm_dumb_allocator_get_type(), "drm-device-path", path, @as(?*anyopaque, null)));
}

pub export fn gst_drm_dumb_allocator_alloc(alloc: [*c]Allocator, fmt: c.guint32, w: c.guint32, h: c.guint32, pitch: [*c]c.guint32) [*c]Memory {
    const m: *DumbMemory = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(DumbMemory))));
    if (!create(dumb(alloc), m, fmt, w, h, pitch)) {
        c.g_free(m);
        return null;
    }
    c.gst_memory_init(&m.parent, 0, alloc, null, m.size, 0, 0, m.size);
    return &m.parent;
}

pub export fn gst_drm_dumb_allocator_has_prime_export(alloc: [*c]Allocator) c.gboolean {
    const a = dumb(alloc);
    if (a.drm_fd < 0) return 0;
    var v: u64 = 0;
    _ = drmGetCap(a.drm_fd, CAP_PRIME, &v);
    return @intFromBool(v & PRIME_CAP_EXPORT != 0);
}
