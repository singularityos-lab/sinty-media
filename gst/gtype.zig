const std = @import("std");
const c = @import("c.zig").c;

pub const Lock = struct {
    m: c.GMutex = std.mem.zeroes(c.GMutex),

    pub fn lock(self: *Lock) void {
        c.g_mutex_lock(&self.m);
    }

    pub fn unlock(self: *Lock) void {
        c.g_mutex_unlock(&self.m);
    }
};

pub const Once = struct {
    value: std.atomic.Value(c.GType) = .init(0),
    mutex: Lock = .{},

    pub fn get(self: *Once, comptime register: fn () c.GType) c.GType {
        const v = self.value.load(.acquire);
        if (v != 0) return v;
        self.mutex.lock();
        defer self.mutex.unlock();
        const again = self.value.load(.acquire);
        if (again != 0) return again;
        const t = register();
        self.value.store(t, .release);
        return t;
    }
};

pub fn object(parent: c.GType, name: [*:0]const u8, comptime Class: type, comptime Instance: type, class_init: c.GClassInitFunc, instance_init: c.GInstanceInitFunc, flags: c.GTypeFlags) c.GType {
    return c.g_type_register_static_simple(parent, name, @sizeOf(Class), class_init, @sizeOf(Instance), instance_init, flags);
}

pub fn boxed(name: [*:0]const u8, copy: c.GBoxedCopyFunc, free: c.GBoxedFreeFunc) c.GType {
    return c.g_boxed_type_register_static(name, copy, free);
}

pub fn typeOf(ptr: anytype) c.GType {
    const inst: *const c.GTypeInstance = @ptrCast(@alignCast(ptr));
    return inst.g_class.*.g_type;
}

pub fn instanceOf(ptr: anytype, t: c.GType) bool {
    const p: ?*const anyopaque = @ptrCast(ptr);
    if (p == null) return false;
    return c.g_type_check_instance_is_a(@ptrCast(@alignCast(@constCast(p))), t) != 0;
}

pub fn classPeek(comptime Class: type, ptr: anytype) *Class {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(ptr));
    return @ptrCast(@alignCast(inst.g_class));
}

pub fn lookup(comptime T: type, comptime symbol: [:0]const u8) T {
    return @ptrCast(@alignCast(c.dlsym(null, symbol.ptr)));
}

var self_handle: ?*anyopaque = null;

fn selfHandle() ?*anyopaque {
    if (self_handle == null) {
        var dl: c.Dl_info = undefined;
        if (c.dladdr(@ptrCast(&selfHandle), &dl) != 0 and dl.dli_fname != null)
            self_handle = c.dlopen(dl.dli_fname, c.RTLD_LAZY | c.RTLD_NOLOAD);
    }
    return self_handle;
}

pub fn own(comptime T: type, comptime symbol: [:0]const u8) T {
    const h = selfHandle() orelse return lookup(T, symbol);
    return @ptrCast(@alignCast(c.dlsym(h, symbol.ptr)));
}

pub fn weakType(comptime symbol: [:0]const u8) c.GType {
    const f = own(?*const fn () callconv(.c) c.GType, symbol) orelse return 0;
    return f();
}
