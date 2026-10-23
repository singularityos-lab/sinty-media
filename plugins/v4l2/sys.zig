pub const v = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("linux/videodev2.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/eventfd.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("time.h");
});

const READ: u32 = 2;
const WRITE: u32 = 1;

fn ioc(dir: u32, nr: u32, comptime T: type) c_ulong {
    return (dir << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, 'V') << 8) | nr;
}

pub const QUERYCAP = ioc(READ, 0, v.struct_v4l2_capability);
pub const ENUM_FMT = ioc(READ | WRITE, 2, v.struct_v4l2_fmtdesc);
pub const G_FMT = ioc(READ | WRITE, 4, v.struct_v4l2_format);
pub const S_FMT = ioc(READ | WRITE, 5, v.struct_v4l2_format);
pub const REQBUFS = ioc(READ | WRITE, 8, v.struct_v4l2_requestbuffers);
pub const QUERYBUF = ioc(READ | WRITE, 9, v.struct_v4l2_buffer);
pub const QBUF = ioc(READ | WRITE, 15, v.struct_v4l2_buffer);
pub const DQBUF = ioc(READ | WRITE, 17, v.struct_v4l2_buffer);
pub const STREAMON = ioc(WRITE, 18, c_int);
pub const STREAMOFF = ioc(WRITE, 19, c_int);
pub const G_PARM = ioc(READ | WRITE, 21, v.struct_v4l2_streamparm);
pub const S_PARM = ioc(READ | WRITE, 22, v.struct_v4l2_streamparm);
pub const ENUMINPUT = ioc(READ | WRITE, 26, v.struct_v4l2_input);
pub const G_CTRL = ioc(READ | WRITE, 27, v.struct_v4l2_control);
pub const S_CTRL = ioc(READ | WRITE, 28, v.struct_v4l2_control);
pub const QUERYCTRL = ioc(READ | WRITE, 36, v.struct_v4l2_queryctrl);
pub const G_INPUT = ioc(READ, 38, c_int);
pub const CROPCAP = ioc(READ | WRITE, 58, v.struct_v4l2_cropcap);
pub const ENUM_FRAMESIZES = ioc(READ | WRITE, 74, v.struct_v4l2_frmsizeenum);
pub const ENUM_FRAMEINTERVALS = ioc(READ | WRITE, 75, v.struct_v4l2_frmivalenum);
pub const TRY_FMT = ioc(READ | WRITE, 64, v.struct_v4l2_format);
pub const G_SELECTION = ioc(READ | WRITE, 94, v.struct_v4l2_selection);
pub const S_SELECTION = ioc(READ | WRITE, 95, v.struct_v4l2_selection);

pub extern fn ioctl(fd: c_int, req: c_ulong, ...) c_int;

pub fn xioctl(fd: c_int, req: c_ulong, arg: anytype) c_int {
    while (true) {
        const r = ioctl(fd, req, arg);
        if (r < 0 and errno() == v.EINTR) continue;
        return r;
    }
}

pub fn errno() c_int {
    return @import("std").c._errno().*;
}

pub fn fourcc(s: *const [4]u8) u32 {
    return @as(u32, s[0]) | @as(u32, s[1]) << 8 | @as(u32, s[2]) << 16 | @as(u32, s[3]) << 24;
}

pub fn fourccBe(s: *const [4]u8) u32 {
    return fourcc(s) | (@as(u32, 1) << 31);
}
