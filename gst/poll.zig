const std = @import("std");
const linux = std.os.linux;
const c = @import("c.zig").c;
const check = @import("check.zig");

comptime {
    @import("abi.zig").check(@This());
}

const PollFD = c.GstPollFD;
const NONE: u64 = std.math.maxInt(u64);

const Slot = extern struct { fd: i32, events: i16, revents: i16 };

const Poll = struct {
    lock: c.GMutex,
    fds: std.ArrayListUnmanaged(Slot),
    active: std.ArrayListUnmanaged(Slot),
    control: PollFD,
    pending: c.gint,
    controllable: bool,
    timer: bool,
    waiting: c.gint,
    flushing: c.gint,
    rebuild: c.gint,
};

const Handle = ?*c.GstPoll;
const Const = ?*const c.GstPoll;
const alloc = std.heap.c_allocator;

fn of(h: anytype) *Poll {
    return @ptrCast(@alignCast(@constCast(h)));
}

fn setErrno(e: linux.E) void {
    std.c._errno().* = @intFromEnum(e);
}

fn find(list: *std.ArrayListUnmanaged(Slot), fd: [*c]PollFD) i32 {
    const items = list.items;
    if (fd[0].idx >= 0 and fd[0].idx < items.len and items[@intCast(fd[0].idx)].fd == fd[0].fd) return fd[0].idx;
    for (items, 0..) |s, i| if (s.fd == fd[0].fd) {
        fd[0].idx = @intCast(i);
        return fd[0].idx;
    };
    fd[0].idx = -1;
    return -1;
}

fn addLocked(p: *Poll, fd: [*c]PollFD) void {
    if (find(&p.fds, fd) >= 0) return;
    p.fds.append(alloc, .{ .fd = fd[0].fd, .events = linux.POLL.ERR | linux.POLL.NVAL | linux.POLL.HUP, .revents = 0 }) catch @panic("out of memory");
    fd[0].idx = @intCast(p.fds.items.len - 1);
    @atomicStore(c.gint, &p.rebuild, 1, .seq_cst);
}

fn setEvent(p: *Poll, fd: [*c]PollFD, bit: i16, on: c.gboolean) bool {
    const i = find(&p.fds, fd);
    if (i < 0) return false;
    const s = &p.fds.items[@intCast(i)];
    if (on != 0) s.events |= bit else s.events &= ~bit;
    @atomicStore(c.gint, &p.rebuild, 1, .seq_cst);
    return true;
}

fn wake(p: *Poll) bool {
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (p.pending == 0) {
        const one: u64 = 1;
        while (true) {
            const r = linux.write(p.control.fd, @ptrCast(&one), 8);
            if (linux.errno(r) == .SUCCESS) break;
            if (linux.errno(r) != .INTR and linux.errno(r) != .AGAIN) return false;
        }
    }
    p.pending += 1;
    return true;
}

fn drain(p: *Poll) bool {
    var v: u64 = 0;
    while (true) {
        const r = linux.read(p.control.fd, @ptrCast(&v), 8);
        if (linux.errno(r) == .SUCCESS) return true;
        const e = linux.errno(r);
        if (e != .INTR and e != .AGAIN) {
            c.g_log("GStreamer", c.G_LOG_LEVEL_CRITICAL, "%p: failed to release event: %s", p, c.g_strerror(@intFromEnum(e)));
            return false;
        }
    }
}

fn release(p: *Poll) bool {
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    if (p.pending == 0) {
        setErrno(.AGAIN);
        return false;
    }
    if (p.pending == 1 and !drain(p)) return false;
    p.pending -= 1;
    return true;
}

fn releaseAll(p: *Poll) c.gint {
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    const old = p.pending;
    if (old == 0) return 0;
    if (!drain(p)) return 0;
    p.pending = 0;
    return old;
}

pub export fn gst_poll_new(controllable: c.gboolean) Handle {
    const p = alloc.create(Poll) catch return null;
    p.* = .{ .lock = undefined, .fds = .empty, .active = .empty, .control = .{ .fd = -1, .idx = -1 }, .pending = 0, .controllable = controllable != 0, .timer = false, .waiting = 0, .flushing = 0, .rebuild = 1 };
    c.g_mutex_init(&p.lock);
    const fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(fd) != .SUCCESS) {
        gst_poll_free(@ptrCast(p));
        return null;
    }
    p.control.fd = @intCast(fd);
    addLocked(p, &p.control);
    _ = setEvent(p, &p.control, linux.POLL.IN, 1);
    return @ptrCast(p);
}

pub export fn gst_poll_new_timer() Handle {
    const h = gst_poll_new(1) orelse return null;
    of(h).timer = true;
    return h;
}

pub export fn gst_poll_free(h: Handle) void {
    if (!check.that(h != null, "gst_poll_free", "set != NULL")) return;
    const p = of(h);
    if (p.control.fd >= 0) _ = linux.close(p.control.fd);
    p.fds.deinit(alloc);
    p.active.deinit(alloc);
    c.g_mutex_clear(&p.lock);
    alloc.destroy(p);
}

pub export fn gst_poll_get_read_gpollfd(h: Handle, fd: [*c]c.GPollFD) void {
    if (!check.that(h != null, "gst_poll_get_read_gpollfd", "set != NULL")) return;
    if (!check.that(fd != null, "gst_poll_get_read_gpollfd", "fd != NULL")) return;
    fd[0].fd = of(h).control.fd;
    fd[0].events = c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR;
    fd[0].revents = 0;
}

pub export fn gst_poll_fd_init(fd: [*c]PollFD) void {
    if (!check.that(fd != null, "gst_poll_fd_init", "fd != NULL")) return;
    fd[0].fd = -1;
    fd[0].idx = -1;
}

fn guard(comptime f: []const u8, h: anytype, fd: [*c]PollFD) bool {
    if (!check.that(h != null, f, "set != NULL")) return false;
    if (!check.that(fd != null, f, "fd != NULL")) return false;
    return check.that(fd[0].fd >= 0, f, "fd->fd >= 0");
}

pub export fn gst_poll_add_fd(h: Handle, fd: [*c]PollFD) c.gboolean {
    if (!guard("gst_poll_add_fd", h, fd)) return 0;
    const p = of(h);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    addLocked(p, fd);
    return 1;
}

pub export fn gst_poll_remove_fd(h: Handle, fd: [*c]PollFD) c.gboolean {
    if (!guard("gst_poll_remove_fd", h, fd)) return 0;
    const p = of(h);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    const i = find(&p.fds, fd);
    if (i < 0) return 0;
    _ = p.fds.swapRemove(@intCast(i));
    fd[0].idx = -1;
    @atomicStore(c.gint, &p.rebuild, 1, .seq_cst);
    return 1;
}

fn control(comptime f: []const u8, h: Handle, fd: [*c]PollFD, bit: i16, on: c.gboolean) c.gboolean {
    if (!guard(f, h, fd)) return 0;
    const p = of(h);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    return @intFromBool(setEvent(p, fd, bit, on));
}

pub export fn gst_poll_fd_ctl_write(h: Handle, fd: [*c]PollFD, on: c.gboolean) c.gboolean {
    return control("gst_poll_fd_ctl_write", h, fd, linux.POLL.OUT, on);
}

pub export fn gst_poll_fd_ctl_read(h: Handle, fd: [*c]PollFD, on: c.gboolean) c.gboolean {
    return control("gst_poll_fd_ctl_read", h, fd, linux.POLL.IN, on);
}

pub export fn gst_poll_fd_ctl_pri(h: Handle, fd: [*c]PollFD, on: c.gboolean) c.gboolean {
    return control("gst_poll_fd_ctl_pri", h, fd, linux.POLL.PRI, on);
}

pub export fn gst_poll_fd_ignored(_: Handle, _: [*c]PollFD) void {}

fn result(comptime f: []const u8, h: Const, fd: [*c]PollFD, mask: i16) c.gboolean {
    if (!guard(f, h, fd)) return 0;
    const p = of(h);
    c.g_mutex_lock(&p.lock);
    defer c.g_mutex_unlock(&p.lock);
    const i = find(&p.active, fd);
    if (i < 0) return 0;
    return @intFromBool(p.active.items[@intCast(i)].revents & mask != 0);
}

pub export fn gst_poll_fd_has_closed(h: Const, fd: [*c]PollFD) c.gboolean {
    return result("gst_poll_fd_has_closed", h, fd, linux.POLL.HUP);
}

pub export fn gst_poll_fd_has_error(h: Const, fd: [*c]PollFD) c.gboolean {
    return result("gst_poll_fd_has_error", h, fd, linux.POLL.ERR | linux.POLL.NVAL);
}

pub export fn gst_poll_fd_can_read(h: Const, fd: [*c]PollFD) c.gboolean {
    return result("gst_poll_fd_can_read", h, fd, linux.POLL.IN);
}

pub export fn gst_poll_fd_can_write(h: Const, fd: [*c]PollFD) c.gboolean {
    return result("gst_poll_fd_can_write", h, fd, linux.POLL.OUT);
}

pub export fn gst_poll_fd_has_pri(h: Const, fd: [*c]PollFD) c.gboolean {
    return result("gst_poll_fd_has_pri", h, fd, linux.POLL.PRI);
}

pub export fn gst_poll_wait(h: Handle, timeout: c.GstClockTime) c.gint {
    if (!check.that(h != null, "gst_poll_wait", "set != NULL")) return -1;
    const p = of(h);
    const old = @atomicRmw(c.gint, &p.waiting, .Add, 1, .seq_cst);
    defer _ = @atomicRmw(c.gint, &p.waiting, .Sub, 1, .seq_cst);
    if (old > 0 and !p.timer) {
        setErrno(.PERM);
        return -1;
    }
    if (@atomicLoad(c.gint, &p.flushing, .seq_cst) != 0) {
        setErrno(.BUSY);
        return -1;
    }
    while (true) {
        if (@cmpxchgStrong(c.gint, &p.rebuild, 1, 0, .seq_cst, .seq_cst) == null) {
            c.g_mutex_lock(&p.lock);
            p.active.resize(alloc, p.fds.items.len) catch @panic("out of memory");
            @memcpy(p.active.items, p.fds.items);
            c.g_mutex_unlock(&p.lock);
        }
        var ts: linux.timespec = undefined;
        const tp: ?*const linux.timespec = if (timeout == NONE) null else blk: {
            ts = .{ .sec = @intCast(timeout / 1000000000), .nsec = @intCast(timeout % 1000000000) };
            break :blk &ts;
        };
        const r = linux.ppoll(@ptrCast(p.active.items.ptr), @intCast(p.active.items.len), @constCast(tp), null);
        var res: c.gint = -1;
        if (linux.errno(r) == .SUCCESS) res = @intCast(r) else setErrno(linux.errno(r));
        var again = false;
        if (!p.timer and releaseAll(p) > 0 and res == 1) again = true;
        if (@atomicLoad(c.gint, &p.flushing, .seq_cst) != 0) {
            setErrno(.BUSY);
            return -1;
        }
        if (!again) return res;
    }
}

pub export fn gst_poll_set_controllable(h: Handle, on: c.gboolean) c.gboolean {
    if (!check.that(h != null, "gst_poll_set_controllable", "set != NULL")) return 0;
    if (!check.that(!of(h).timer, "gst_poll_set_controllable", "!set->timer")) return 0;
    of(h).controllable = on != 0;
    return 1;
}

pub export fn gst_poll_restart(h: Handle) void {
    if (!check.that(h != null, "gst_poll_restart", "set != NULL")) return;
    const p = of(h);
    if (!check.that(!p.timer, "gst_poll_restart", "!set->timer")) return;
    if (p.controllable and @atomicLoad(c.gint, &p.waiting, .seq_cst) > 0) _ = wake(p);
}

pub export fn gst_poll_set_flushing(h: Handle, on: c.gboolean) void {
    if (!check.that(h != null, "gst_poll_set_flushing", "set != NULL")) return;
    const p = of(h);
    if (!check.that(!p.timer, "gst_poll_set_flushing", "!set->timer")) return;
    @atomicStore(c.gint, &p.flushing, @intFromBool(on != 0), .seq_cst);
    if (on != 0 and p.controllable and @atomicLoad(c.gint, &p.waiting, .seq_cst) > 0) _ = wake(p);
}

pub export fn gst_poll_write_control(h: Handle) c.gboolean {
    if (!check.that(h != null, "gst_poll_write_control", "set != NULL")) return 0;
    if (!check.that(of(h).timer, "gst_poll_write_control", "set->timer")) return 0;
    return @intFromBool(wake(of(h)));
}

pub export fn gst_poll_read_control(h: Handle) c.gboolean {
    if (!check.that(h != null, "gst_poll_read_control", "set != NULL")) return 0;
    if (!check.that(of(h).timer, "gst_poll_read_control", "set->timer")) return 0;
    return @intFromBool(release(of(h)));
}
