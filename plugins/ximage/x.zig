pub const p = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/XKBlib.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("X11/extensions/XInput2.h");
    @cInclude("sys/ipc.h");
    @cInclude("sys/shm.h");
});

pub const NO_ADDR: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub fn destroyImage(img: [*c]p.XImage) void {
    _ = img[0].f.destroy_image.?(img);
}

pub fn setMask(mask: [*]u8, ev: c_int) void {
    const e: usize = @intCast(ev);
    mask[e >> 3] |= @as(u8, 1) << @intCast(e & 7);
}

pub const BASE_MASK = p.ExposureMask | p.StructureNotifyMask | p.PointerMotionMask | p.KeyPressMask | p.KeyReleaseMask;
pub const FULL_MASK = BASE_MASK | p.ButtonPressMask | p.ButtonReleaseMask;
