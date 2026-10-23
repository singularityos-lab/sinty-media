pub const s = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/resource.h");
    @cInclude("sched.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/stat.h");
});

pub extern fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
pub extern fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
pub extern fn accept4(fd: c_int, addr: ?*anyopaque, len: ?*c_uint, flags: c_int) c_int;

pub const HDR = @sizeOf(s.struct_cmsghdr);

pub fn cmsgLen(n: usize) usize {
    return HDR + n;
}

pub fn cmsgSpace(comptime n: usize) usize {
    return HDR + ((n + @sizeOf(usize) - 1) & ~@as(usize, @sizeOf(usize) - 1));
}

pub fn cmsgData(cm: *s.struct_cmsghdr) [*]align(1) c_int {
    return @ptrCast(@as([*]u8, @ptrCast(cm)) + HDR);
}
