const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const dmabuf = @import("dmabuf.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Memory = c.GstMemory;
const Allocator = c.GstAllocator;
const linux = std.os.linux;

const Create = extern struct { memfd: u32, flags: u32, offset: u64, size: u64 };
const CREATE_IOCTL = linux.IOCTL.IOW('u', 0x42, Create);

const Udma = extern struct {
    parent: c.GstDmaBufAllocator,
    dev_fd: c_int,
};

const UdmaClass = extern struct {
    parent: c.GstDmaBufAllocatorClass,
};

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;
var init_done: usize = 0;

fn alloc(allocator: [*c]Allocator, size: usize, params: [*c]c.GstAllocationParams) callconv(.c) [*c]Memory {
    const self: *Udma = @ptrCast(@alignCast(allocator));
    const p = params[0];
    var maxsize = size;
    if (@addWithOverflow(maxsize, p.prefix)[1] != 0) return null;
    maxsize += p.prefix;
    if (@addWithOverflow(maxsize, p.padding)[1] != 0) return null;
    maxsize += p.padding;
    if (@addWithOverflow(maxsize, p.@"align")[1] != 0) return null;
    maxsize += p.@"align";
    maxsize &= ~p.@"align";
    const mask: usize = std.heap.pageSize() - 1;
    if (@addWithOverflow(maxsize, mask)[1] != 0) return null;
    maxsize = (maxsize + mask) & ~mask;
    const r = linux.memfd_create("gst-udmabuf", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(r) != .SUCCESS) return null;
    const f: c_int = @intCast(r);
    if (std.c.ftruncate(f, @intCast(maxsize)) < 0 or std.c.fcntl(f, linux.F.ADD_SEALS, @as(c_int, linux.F.SEAL_SHRINK)) < 0) {
        _ = std.c.close(f);
        return null;
    }
    var cr = Create{ .memfd = @intCast(f), .flags = 0x01, .offset = 0, .size = maxsize };
    const u = linux.ioctl(self.dev_fd, CREATE_IOCTL, @intFromPtr(&cr));
    if (linux.errno(u) != .SUCCESS) {
        _ = std.c.close(f);
        return null;
    }
    _ = std.c.close(f);
    const ufd: c_int = @intCast(u);
    const mem = dmabuf.gst_dmabuf_allocator_alloc_with_flags(allocator, ufd, maxsize, c.GST_FD_MEMORY_FLAG_KEEP_MAPPED);
    if (mem == null) {
        _ = std.c.close(ufd);
        return null;
    }
    mem[0].@"align" = p.@"align";
    mem[0].maxsize = maxsize;
    mem[0].offset = p.prefix;
    mem[0].size = size;
    if (p.flags & c.GST_MEMORY_FLAG_ZERO_PREFIXED != 0 or p.flags & c.GST_MEMORY_FLAG_ZERO_PADDED != 0) {
        const d: ?[*]u8 = @ptrCast(mem[0].allocator[0].mem_map.?(mem, mem[0].maxsize, c.GST_MAP_WRITE));
        if (d == null) {
            c.gst_mini_object_unref(@ptrCast(mem));
            return null;
        }
        if (p.prefix != 0 and p.flags & c.GST_MEMORY_FLAG_ZERO_PREFIXED != 0) @memset(d.?[0..p.prefix], 0);
        const padding = maxsize - (p.prefix + size);
        if (padding != 0 and p.flags & c.GST_MEMORY_FLAG_ZERO_PADDED != 0) @memset(d.?[p.prefix + size .. p.prefix + size + padding], 0);
        mem[0].allocator[0].mem_unmap.?(mem);
    }
    return mem;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const self: *Udma = @ptrCast(@alignCast(o));
    if (self.dev_fd != -1) {
        _ = std.c.close(self.dev_fd);
        self.dev_fd = -1;
    }
    parent.?.finalize.?(o);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    @as(*c.GstAllocatorClass, @ptrCast(@alignCast(k))).alloc = alloc;
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self: *Udma = @ptrCast(@alignCast(inst));
    const a: *Allocator = @ptrCast(@alignCast(inst));
    a.mem_type = c.GST_ALLOCATOR_UDMABUF;
    self.dev_fd = std.c.open("/dev/udmabuf", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    a.object.flags &= ~@as(c.guint32, c.GST_ALLOCATOR_FLAG_CUSTOM_ALLOC);
}

pub export fn gst_udmabuf_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(dmabuf.gst_dmabuf_allocator_get_type, "GstUdmabufAllocator", UdmaClass, Udma, classInit, init, 0);
            _ = c._gst_debug_category_new("udmabuf-allocator", 0, "udmabuf allocator");
            _ = c._gst_debug_get_category("GST_PERFORMANCE");
            return t;
        }
    }.f);
}

pub export fn gst_udmabuf_allocator_init_once() void {
    if (c.g_once_init_enter(&init_done) != 0) {
        const a: *Udma = @ptrCast(@alignCast(c.g_object_new(gst_udmabuf_allocator_get_type(), @as([*c]const u8, null))));
        _ = c.gst_object_ref_sink(a);
        if (a.dev_fd != -1) c.gst_allocator_register(c.GST_ALLOCATOR_UDMABUF, @ptrCast(a)) else c.gst_object_unref(a);
        c.g_once_init_leave(&init_done, 1);
    }
}

pub export fn gst_udmabuf_allocator_get() [*c]Allocator {
    gst_udmabuf_allocator_init_once();
    return c.gst_allocator_find(c.GST_ALLOCATOR_UDMABUF);
}
