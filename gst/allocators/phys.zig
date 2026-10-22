const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var once: gtype.Once = .{};

fn defaultInit(_: c.gpointer, _: c.gpointer) callconv(.c) void {}

pub export fn gst_phys_memory_allocator_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = c.g_type_register_static_simple(c.G_TYPE_INTERFACE, c.g_intern_static_string("GstPhysMemoryAllocator"), @sizeOf(c.GstPhysMemoryAllocatorInterface), defaultInit, 0, null, 0);
            c.g_type_interface_add_prerequisite(t, c.gst_allocator_get_type());
            return t;
        }
    }.f);
}

pub export fn gst_is_phys_memory(mem: [*c]c.GstMemory) c.gboolean {
    return @intFromBool(mem != null and mem[0].allocator != null and c.g_type_is_a(gtype.typeOf(mem[0].allocator), gst_phys_memory_allocator_get_type()) != 0);
}

pub export fn gst_phys_memory_get_phys_addr(mem: [*c]c.GstMemory) c.guintptr {
    if (!check.that(gst_is_phys_memory(mem) != 0, "gst_phys_memory_get_phys_addr", "gst_is_phys_memory (mem)")) return 0;
    const iface: *c.GstPhysMemoryAllocatorInterface = @ptrCast(@alignCast(c.g_type_interface_peek(@as(*c.GTypeInstance, @ptrCast(@alignCast(mem[0].allocator))).g_class, gst_phys_memory_allocator_get_type())));
    if (!check.that(iface.get_phys_addr != null, "gst_phys_memory_get_phys_addr", "iface->get_phys_addr != NULL")) return 0;
    return iface.get_phys_addr.?(@ptrCast(mem[0].allocator), mem);
}
