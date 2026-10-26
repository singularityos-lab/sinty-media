const std = @import("std");
const X = @import("sys.zig");
pub const sys = X.s;
const S = sys;

pub const Kind = enum(u32) { open = 1, release, close, ready, caps, frame, eos, failure, play, data, need, control, state };

pub const FLAG_ISOLATED: u32 = 1;
pub const FLAG_LIVE: u32 = 1;
pub const FLAG_DMABUF: u32 = 2;

pub const Head = extern struct {
    kind: u32,
    size: u32,
};

pub const Frame = extern struct {
    id: u64,
    slot: i64,
    flags: u32,
    buffer_flags: u32,
    offset: u64,
    size: u64,
    maxsize: u64,
    pts: u64,
    dts: u64,
    duration: u64,
};

pub const Play = extern struct {
    flags: u32,
    pad: u32 = 0,
    size: u64,
};

pub const Need = extern struct {
    offset: u64,
    length: u32,
    pad: u32 = 0,
};

pub const Op = enum(u32) { play = 1, pause, seek, rate, volume, mute };

pub const Control = extern struct {
    op: u32,
    pad: u32 = 0,
    value: f64,
};

pub const STATE_PLAYING: u32 = 1;
pub const STATE_SEEKABLE: u32 = 2;

pub const State = extern struct {
    position: i64,
    duration: i64,
    flags: u32,
    pad: u32 = 0,
};

pub const CHUNK = MAX - @sizeOf(Head) - 8;

pub const Failure = extern struct {
    domain: u32,
    code: i32,
};

pub const MAX = 65536;
pub const bindTo = X.bind;
pub const acceptOn = X.accept4;

pub fn socketPath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("SINTY_MEDIAD_SOCKET")) |p| return std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(p)}) catch null;
    const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/sinty-mediad.sock", .{std.mem.span(dir)}) catch null;
}

pub fn connect(path: [:0]const u8) c_int {
    const fd = S.socket(S.AF_UNIX, S.SOCK_SEQPACKET | S.SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    var addr = std.mem.zeroes(S.struct_sockaddr_un);
    addr.sun_family = S.AF_UNIX;
    if (path.len >= addr.sun_path.len) {
        _ = S.close(fd);
        return -1;
    }
    @memcpy(addr.sun_path[0..path.len], path);
    if (X.connect(fd, &addr, @sizeOf(S.struct_sockaddr_un)) != 0) {
        _ = S.close(fd);
        return -1;
    }
    return fd;
}

pub fn send(fd: c_int, kind: Kind, parts: []const []const u8, pass: c_int, nonblock: bool) bool {
    var total: usize = 0;
    for (parts) |p| total += p.len;
    var head = Head{ .kind = @intFromEnum(kind), .size = @intCast(total) };
    var iov: [8]S.struct_iovec = undefined;
    iov[0] = .{ .iov_base = @ptrCast(&head), .iov_len = @sizeOf(Head) };
    for (parts, 1..) |p, i| iov[i] = .{ .iov_base = @constCast(@ptrCast(p.ptr)), .iov_len = p.len };
    var msg = std.mem.zeroes(S.struct_msghdr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = parts.len + 1;
    var ctl: [X.cmsgSpace(@sizeOf(c_int))]u8 align(@alignOf(S.struct_cmsghdr)) = undefined;
    if (pass >= 0) {
        msg.msg_control = &ctl;
        msg.msg_controllen = ctl.len;
        const cm: *S.struct_cmsghdr = @ptrCast(&ctl);
        cm.cmsg_level = S.SOL_SOCKET;
        cm.cmsg_type = S.SCM_RIGHTS;
        cm.cmsg_len = X.cmsgLen(@sizeOf(c_int));
        X.cmsgData(cm)[0] = pass;
    }
    const flags: c_int = S.MSG_NOSIGNAL | @as(c_int, if (nonblock) S.MSG_DONTWAIT else 0);
    while (true) {
        const n = S.sendmsg(fd, &msg, flags);
        if (n >= 0) return true;
        if (std.c._errno().* == S.EINTR) continue;
        return false;
    }
}

pub const Msg = struct {
    kind: Kind,
    body: []u8,
    fd: c_int,
};

pub fn recv(fd: c_int, buf: []u8) ?Msg {
    var iov = S.struct_iovec{ .iov_base = buf.ptr, .iov_len = buf.len };
    var msg = std.mem.zeroes(S.struct_msghdr);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    var ctl: [X.cmsgSpace(@sizeOf(c_int) * 4)]u8 align(@alignOf(S.struct_cmsghdr)) = undefined;
    msg.msg_control = &ctl;
    msg.msg_controllen = ctl.len;
    var n: isize = 0;
    while (true) {
        n = S.recvmsg(fd, &msg, S.MSG_CMSG_CLOEXEC);
        if (n >= 0) break;
        if (std.c._errno().* == S.EINTR) continue;
        return null;
    }
    var got: c_int = -1;
    if (msg.msg_controllen >= @sizeOf(S.struct_cmsghdr)) {
        const cm: *S.struct_cmsghdr = @ptrCast(&ctl);
        if (cm.cmsg_level == S.SOL_SOCKET and cm.cmsg_type == S.SCM_RIGHTS) {
            const data = X.cmsgData(cm);
            got = data[0];
            const count = (cm.cmsg_len - X.HDR) / @sizeOf(c_int);
            var i: usize = 1;
            while (i < count) : (i += 1) _ = S.close(data[i]);
        }
    }
    if (n < @sizeOf(Head) or msg.msg_flags & S.MSG_TRUNC != 0) {
        if (got >= 0) _ = S.close(got);
        return null;
    }
    const head: *align(1) const Head = @ptrCast(buf.ptr);
    if (head.size + @sizeOf(Head) != n) {
        if (got >= 0) _ = S.close(got);
        return null;
    }
    const kind = std.enums.fromInt(Kind, head.kind) orelse {
        if (got >= 0) _ = S.close(got);
        return null;
    };
    return .{ .kind = kind, .body = buf[@sizeOf(Head)..@intCast(n)], .fd = got };
}

pub fn asStruct(comptime T: type, body: []const u8) ?T {
    if (body.len < @sizeOf(T)) return null;
    var v: T = undefined;
    @memcpy(std.mem.asBytes(&v), body[0..@sizeOf(T)]);
    return v;
}

pub fn strings(body: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, 0);
    while (it.next()) |p| {
        if (n == out.len) break;
        out[n] = p;
        n += 1;
    }
    return n;
}
