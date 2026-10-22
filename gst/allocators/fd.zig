const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const linux = std.os.linux;

pub const FdMemory = extern struct {
    mem: Memory,
    flags: c.GstFdMemoryFlags,
    fd: c.gint,
    data: ?*anyopaque,
    mmapping_flags: c.gint,
    mmap_count: c.gint,
    lock: c.GMutex,
};

var once: gtype.Once = .{};
var parent: ?*c.GstAllocatorClass = null;

pub fn fdMem(m: anytype) *FdMemory {
    return @ptrCast(@alignCast(m));
}

pub fn isFdAllocator(a: anytype) bool {
    return gtype.instanceOf(a, gst_fd_allocator_get_type());
}

fn memFree(_: ?*Allocator, gmem: [*c]Memory) callconv(.c) void {
    const m = fdMem(gmem);
    if (m.data != null) {
        if (m.flags & c.GST_FD_MEMORY_FLAG_KEEP_MAPPED == 0) c.g_log(check.DOMAIN, c.G_LOG_LEVEL_WARNING, "../gst-libs/gst/allocators/gstfdmemory.c:64:%s: Freeing memory %p still mapped", "gst_fd_mem_free", gmem);
        _ = linux.munmap(@ptrCast(@alignCast(m.data)), gmem[0].maxsize);
    }
    if (m.fd >= 0 and gmem[0].parent == null and m.flags & c.GST_FD_MEMORY_FLAG_DONT_CLOSE == 0) _ = std.c.close(m.fd);
    c.g_mutex_clear(&m.lock);
    c.g_free(m);
}

fn memMap(gmem: [*c]Memory, maxsize: usize, flags: c.GstMapFlags) callconv(.c) c.gpointer {
    if (gmem[0].parent != null) return memMap(gmem[0].parent, maxsize, flags);
    const m = fdMem(gmem);
    var prot: c.gint = if (flags & c.GST_MAP_READ != 0) 1 else 0;
    if (flags & c.GST_MAP_WRITE != 0) prot |= 2;
    c.g_mutex_lock(&m.lock);
    defer c.g_mutex_unlock(&m.lock);
    if (m.data != null) {
        if (m.mmapping_flags & prot == prot) {
            m.mmap_count += 1;
            return m.data;
        }
        if (m.flags & c.GST_FD_MEMORY_FLAG_KEEP_MAPPED != 0 and m.mmap_count == 0 and std.c.mprotect(@ptrCast(@alignCast(m.data)), gmem[0].maxsize, @bitCast(@as(u32, @bitCast(prot)))) == 0) {
            m.mmapping_flags = prot;
            m.mmap_count += 1;
            return m.data;
        }
        return null;
    }
    if (m.fd != -1) {
        const mf: linux.MAP = if (m.flags & c.GST_FD_MEMORY_FLAG_MAP_PRIVATE != 0) .{ .TYPE = .PRIVATE } else .{ .TYPE = .SHARED };
        const r = linux.mmap(null, gmem[0].maxsize, @bitCast(@as(u32, @bitCast(prot))), mf, m.fd, 0);
        if (linux.errno(r) != .SUCCESS) return null;
        m.data = @ptrFromInt(r);
    }
    if (m.data == null) return null;
    m.mmapping_flags = prot;
    m.mmap_count += 1;
    return m.data;
}

fn memUnmap(gmem: [*c]Memory) callconv(.c) void {
    if (gmem[0].parent != null) return memUnmap(gmem[0].parent);
    const m = fdMem(gmem);
    c.g_mutex_lock(&m.lock);
    defer c.g_mutex_unlock(&m.lock);
    if (m.flags & c.GST_FD_MEMORY_FLAG_KEEP_MAPPED != 0) {
        m.mmap_count -= 1;
        return;
    }
    if (m.data != null) {
        m.mmap_count -= 1;
        if (m.mmap_count == 0) {
            _ = linux.munmap(@ptrCast(@alignCast(m.data)), gmem[0].maxsize);
            m.data = null;
            m.mmapping_flags = 0;
        }
    }
}

fn memShare(gmem: [*c]Memory, offset: isize, size_in: isize) callconv(.c) [*c]Memory {
    const m = fdMem(gmem);
    const par: [*c]Memory = if (m.mem.parent != null) m.mem.parent else gmem;
    const size: isize = if (size_in == -1) @as(isize, @bitCast(gmem[0].size)) - offset else size_in;
    const sub = fdMem(c.g_malloc0(@sizeOf(FdMemory)));
    c.gst_memory_init(&sub.mem, par[0].mini_object.flags | c.GST_MINI_OBJECT_FLAG_LOCK_READONLY, m.mem.allocator, par, m.mem.maxsize, m.mem.@"align", m.mem.offset +% @as(usize, @bitCast(offset)), @bitCast(size));
    sub.fd = m.fd;
    c.g_mutex_init(&sub.lock);
    return &sub.mem;
}

fn memIsSpan(a: [*c]Memory, b: [*c]Memory, offset: [*c]usize) callconv(.c) c.gboolean {
    if (gst_fd_memory_get_fd(a) != gst_fd_memory_get_fd(b)) return 0;
    if (a[0].offset + a[0].size != b[0].offset) return 0;
    if (offset != null) offset[0] = a[0].offset - a[0].parent[0].offset;
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ac: *c.GstAllocatorClass = @ptrCast(@alignCast(k));
    ac.alloc = null;
    ac.free = memFree;
    _ = c._gst_debug_category_new("fdmemory", 0, "GstFdMemory and GstFdAllocator");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(inst));
    a.mem_type = c.GST_ALLOCATOR_FD;
    a.mem_map = memMap;
    a.mem_unmap = memUnmap;
    a.mem_share = memShare;
    a.mem_is_span = memIsSpan;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC;
}

pub export fn gst_fd_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return gtype.object(c.gst_allocator_get_type, "GstFdAllocator", c.GstFdAllocatorClass, c.GstFdAllocator, classInit, init, 0);
        }
    }.f);
}

pub export fn gst_fd_allocator_new() [*c]Allocator {
    const a = c.g_object_new(gst_fd_allocator_get_type(), @as([*c]const u8, null));
    _ = c.gst_object_ref_sink(a);
    return @ptrCast(@alignCast(a));
}

pub export fn gst_fd_allocator_alloc_full(allocator: [*c]Allocator, fd: c.gint, maxsize: c.gsize, offset: c.gsize, size: c.gsize, flags: c.GstFdMemoryFlags) [*c]Memory {
    const fname = "gst_fd_allocator_alloc_full";
    if (!check.that(isFdAllocator(allocator), fname, "GST_IS_FD_ALLOCATOR (allocator)")) return null;
    if (!check.that(offset + size <= maxsize, fname, "offset + size <= maxsize")) return null;
    const m = fdMem(c.g_malloc0(@sizeOf(FdMemory)));
    c.gst_memory_init(&m.mem, 0, allocator, null, maxsize, 0, offset, size);
    m.flags = flags;
    m.fd = fd;
    c.g_mutex_init(&m.lock);
    return &m.mem;
}

pub export fn gst_fd_allocator_alloc(allocator: [*c]Allocator, fd: c.gint, size: c.gsize, flags: c.GstFdMemoryFlags) [*c]Memory {
    return gst_fd_allocator_alloc_full(allocator, fd, size, 0, size, flags);
}

pub export fn gst_is_fd_memory(mem: [*c]Memory) c.gboolean {
    if (!check.that(mem != null, "gst_is_fd_memory", "mem != NULL")) return 0;
    return @intFromBool(isFdAllocator(mem[0].allocator));
}

pub export fn gst_fd_memory_get_fd(mem: [*c]Memory) c.gint {
    if (!check.that(mem != null, "gst_fd_memory_get_fd", "mem != NULL")) return -1;
    if (!check.that(isFdAllocator(mem[0].allocator), "gst_fd_memory_get_fd", "GST_IS_FD_ALLOCATOR (mem->allocator)")) return -1;
    return fdMem(mem).fd;
}
