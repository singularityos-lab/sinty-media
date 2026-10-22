const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const fd = @import("fd.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const linux = std.os.linux;

var once: gtype.Once = .{};
var init_done: usize = 0;

fn alloc(allocator: [*c]Allocator, size: usize, params: [*c]c.GstAllocationParams) callconv(.c) [*c]Memory {
    var maxsize = size + params[0].prefix + params[0].padding;
    var al = params[0].@"align";
    al |= c.gst_memory_alignment;
    maxsize += al;
    const r = linux.memfd_create("gst-shm", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(r) != .SUCCESS) return null;
    const f: c.gint = @intCast(r);
    if (std.c.ftruncate(f, @intCast(maxsize)) < 0) {
        _ = std.c.close(f);
        return null;
    }
    const mem = fd.gst_fd_allocator_alloc(allocator, f, maxsize, c.GST_FD_MEMORY_FLAG_KEEP_MAPPED);
    if (mem == null) {
        _ = std.c.close(f);
        return null;
    }
    var info: c.GstMapInfo = undefined;
    if (c.gst_memory_map(mem, &info, c.GST_MAP_READWRITE) == 0) {
        c.gst_mini_object_unref(@ptrCast(mem));
        return null;
    }
    var data: [*]u8 = @ptrCast(info.data);
    var asize = maxsize;
    var aoffset: usize = @intFromPtr(data) & al;
    if (aoffset != 0) {
        aoffset = (al + 1) - aoffset;
        data += aoffset;
        asize = maxsize - aoffset;
    }
    const p = params[0];
    if (p.prefix != 0 and p.flags & c.GST_MEMORY_FLAG_ZERO_PREFIXED != 0) @memset(data[0..p.prefix], 0);
    const padding = asize - (p.prefix + size);
    if (padding != 0 and p.flags & c.GST_MEMORY_FLAG_ZERO_PADDED != 0) @memset(data[p.prefix + size .. p.prefix + size + padding], 0);
    mem[0].@"align" = al;
    mem[0].size = size;
    mem[0].offset = p.prefix + aoffset;
    c.gst_memory_unmap(mem, &info);
    _ = std.c.fcntl(f, linux.F.ADD_SEALS, @as(c_int, linux.F.SEAL_SHRINK));
    return mem;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = alloc;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const a: *Allocator = @ptrCast(@alignCast(inst));
    a.mem_type = c.GST_ALLOCATOR_SHM;
    a.object.flags |= c.GST_ALLOCATOR_FLAG_NO_COPY;
}

pub export fn gst_shm_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(fd.gst_fd_allocator_get_type, "GstShmAllocator", c.GstShmAllocatorClass, c.GstFdAllocator, classInit, init, 0);
            _ = c._gst_debug_category_new("shmallocator", 0, "Shared memory allocator");
            return t;
        }
    }.f);
}

pub export fn gst_shm_allocator_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        const a = c.g_object_new(gst_shm_allocator_get_type(), @as([*c]const u8, null));
        _ = c.gst_object_ref_sink(a);
        c.gst_allocator_register(c.GST_ALLOCATOR_SHM, @ptrCast(@alignCast(a)));
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_shm_allocator_get() [*c]Allocator {
    return c.gst_allocator_find(c.GST_ALLOCATOR_SHM);
}
