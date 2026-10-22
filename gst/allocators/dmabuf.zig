const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const fd = @import("fd.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const linux = std.os.linux;

const Sync = extern struct { flags: u64 };
const SYNC_IOCTL = linux.IOCTL.IOW('b', 0, Sync);
const SYNC_READ: u64 = 1 << 0;
const SYNC_WRITE: u64 = 2 << 0;
const SYNC_START: u64 = 0 << 2;
const SYNC_END: u64 = 1 << 2;

var once: gtype.Once = .{};

pub fn isDmabufAllocator(a: anytype) bool {
    return gtype.instanceOf(a, gst_dmabuf_allocator_get_type());
}

fn sync(gmem: [*c]Memory, flags: c.GstMapFlags, edge: u64) void {
    var s = Sync{ .flags = edge };
    if (flags & c.GST_MAP_READ != 0) s.flags |= SYNC_READ;
    if (flags & c.GST_MAP_WRITE != 0) s.flags |= SYNC_WRITE;
    _ = linux.ioctl(fd.gst_fd_memory_get_fd(gmem), SYNC_IOCTL, @intFromPtr(&s));
}

fn memMap(gmem: [*c]Memory, info: [*c]c.GstMapInfo, maxsize: usize) callconv(.c) c.gpointer {
    const a = gmem[0].allocator;
    const r = a[0].mem_map.?(gmem, maxsize, info[0].flags);
    if (r != null) sync(gmem, info[0].flags, SYNC_START);
    return r;
}

fn memUnmap(gmem: [*c]Memory, info: [*c]c.GstMapInfo) callconv(.c) void {
    const a = gmem[0].allocator;
    sync(gmem, info[0].flags, SYNC_END);
    a[0].mem_unmap.?(gmem);
}

fn classInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(inst));
    a.mem_type = c.GST_ALLOCATOR_DMABUF;
    a.mem_map_full = memMap;
    a.mem_unmap_full = memUnmap;
}

pub export fn gst_dmabuf_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(fd.gst_fd_allocator_get_type, "GstDmaBufAllocator", c.GstDmaBufAllocatorClass, c.GstDmaBufAllocator, classInit, init, 0);
            _ = c._gst_debug_category_new("dmabuf", 0, "dmabuf memory");
            return t;
        }
    }.f);
}

pub export fn gst_dmabuf_allocator_new() [*c]Allocator {
    const a = c.g_object_new(gst_dmabuf_allocator_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(a);
    return @ptrCast(@alignCast(a));
}

pub export fn gst_dmabuf_allocator_alloc(allocator: [*c]Allocator, f: c.gint, size: c.gsize) [*c]Memory {
    if (!check.that(isDmabufAllocator(allocator), "gst_dmabuf_allocator_alloc", "GST_IS_DMABUF_ALLOCATOR (allocator)")) return null;
    return fd.gst_fd_allocator_alloc(allocator, f, size, c.GST_FD_MEMORY_FLAG_NONE);
}

pub export fn gst_dmabuf_allocator_alloc_with_flags(allocator: [*c]Allocator, f: c.gint, size: c.gsize, flags: c.GstFdMemoryFlags) [*c]Memory {
    if (!check.that(isDmabufAllocator(allocator), "gst_dmabuf_allocator_alloc_with_flags", "GST_IS_DMABUF_ALLOCATOR (allocator)")) return null;
    return fd.gst_fd_allocator_alloc(allocator, f, size, flags);
}

pub export fn gst_dmabuf_memory_get_fd(mem: [*c]Memory) c.gint {
    if (!check.that(gst_is_dmabuf_memory(mem) != 0, "gst_dmabuf_memory_get_fd", "gst_is_dmabuf_memory (mem)")) return -1;
    return fd.gst_fd_memory_get_fd(mem);
}

pub export fn gst_is_dmabuf_memory(mem: [*c]Memory) c.gboolean {
    if (!check.that(mem != null, "gst_is_dmabuf_memory", "mem != NULL")) return 0;
    return @intFromBool(isDmabufAllocator(mem[0].allocator));
}
