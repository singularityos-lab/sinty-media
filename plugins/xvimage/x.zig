pub const p = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/extensions/Xvlib.h");
    @cInclude("X11/extensions/XInput2.h");
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

pub const NO_ADDR: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub fn setMask(mask: [*]u8, ev: c_int) void {
    const e: usize = @intCast(ev);
    mask[e >> 3] |= @as(u8, 1) << @intCast(e & 7);
}

pub fn noAddr(a: [*c]u8) bool {
    return a == @as([*c]u8, @ptrCast(NO_ADDR));
}

pub const BASE_MASK = p.ExposureMask | p.StructureNotifyMask | p.PointerMotionMask | p.KeyPressMask | p.KeyReleaseMask;
pub const FULL_MASK = BASE_MASK | p.ButtonPressMask | p.ButtonReleaseMask;
