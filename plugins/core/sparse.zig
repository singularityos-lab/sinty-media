const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const E = struct {
    const FAILED: c.gint = 0;
    const NOT_FOUND: c.gint = 1;
    const EXISTS: c.gint = 2;
    const IS_DIRECTORY: c.gint = 3;
    const NOT_DIRECTORY: c.gint = 4;
    const NOT_EMPTY: c.gint = 5;
    const FILENAME_TOO_LONG: c.gint = 9;
    const TOO_MANY_LINKS: c.gint = 11;
    const NO_SPACE: c.gint = 12;
    const INVALID_ARGUMENT: c.gint = 13;
    const PERMISSION_DENIED: c.gint = 14;
    const NOT_SUPPORTED: c.gint = 15;
    const CANCELLED: c.gint = 19;
    const READ_ONLY: c.gint = 21;
    const TIMED_OUT: c.gint = 24;
    const BUSY: c.gint = 26;
    const WOULD_BLOCK: c.gint = 27;
    const TOO_MANY_OPEN_FILES: c.gint = 31;
    const ADDRESS_IN_USE: c.gint = 33;
    const HOST_UNREACHABLE: c.gint = 37;
    const NETWORK_UNREACHABLE: c.gint = 38;
    const CONNECTION_REFUSED: c.gint = 39;
    const BROKEN_PIPE: c.gint = 44;
};

pub const WOULD_BLOCK = E.WOULD_BLOCK;

const Range = struct {
    start: usize,
    stop: usize,
};

pub const File = struct {
    fp: ?*c.FILE = null,
    fd: c_int = -1,
    pos: usize = 0,
    writing: bool = false,
    ranges: std.ArrayList(Range) = .empty,

    pub fn create() *File {
        const f = std.heap.c_allocator.create(File) catch @panic("oom");
        f.* = .{};
        return f;
    }

    pub fn setFd(f: *File, fd: c_int) bool {
        f.fp = c.fdopen(fd, "wb+");
        f.fd = fd;
        return f.fp != null;
    }

    pub fn clear(f: *File) void {
        f.ranges.clearRetainingCapacity();
        f.pos = 0;
        f.writing = false;
    }

    pub fn destroy(f: *File) void {
        if (f.fp) |fp| {
            _ = c.fflush(fp);
            _ = c.fclose(fp);
        }
        f.ranges.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(f);
    }

    fn quark() c.GQuark {
        return c.g_quark_from_static_string("gst-sparse-file-io-error-quark");
    }

    fn fail(err: [*c][*c]c.GError, comptime what: [:0]const u8) void {
        const e = std.c._errno().*;
        c.g_set_error(err, quark(), code(e), "Error " ++ what ++ " file: %s", c.g_strerror(e));
    }

    fn seek(f: *File, off: usize) bool {
        return c.fseeko(f.fp, @intCast(off), c.SEEK_SET) == 0;
    }

    fn mark(f: *File, start: usize, stop: usize) usize {
        var i: usize = 0;
        while (i < f.ranges.items.len and f.ranges.items[i].stop < start) : (i += 1) {}
        var j = i;
        var lo = start;
        var hi = stop;
        while (j < f.ranges.items.len and f.ranges.items[j].start <= hi) : (j += 1) {
            lo = @min(lo, f.ranges.items[j].start);
            hi = @max(hi, f.ranges.items[j].stop);
        }
        f.ranges.replaceRange(std.heap.c_allocator, i, j - i, &.{.{ .start = lo, .stop = hi }}) catch @panic("oom");
        return hi;
    }

    pub fn write(f: *File, off: usize, data: [*]const u8, n: usize, available: ?*usize, err: [*c][*c]c.GError) usize {
        if (f.fp) |fp| {
            if (f.pos != off) {
                if (!f.seek(off)) {
                    fail(err, "writing");
                    return 0;
                }
            } else if (!f.writing) _ = c.fflush(fp);
            f.writing = true;
            if (c.fwrite(data, n, 1, fp) != 1) {
                fail(err, "writing");
                return 0;
            }
        }
        f.pos = off + n;
        const hi = f.mark(off, off + n);
        if (available) |a| a.* = hi - (off + n);
        return n;
    }

    fn covering(f: *File, off: usize, n: usize) ?Range {
        for (f.ranges.items) |r| {
            if (r.start > off) break;
            if (r.stop > off and r.stop >= off + n) return r;
            if (r.start <= off and r.stop > off) return null;
        }
        return null;
    }

    pub fn read(f: *File, off: usize, data: [*]u8, n: usize, remaining: ?*usize, err: [*c][*c]c.GError) usize {
        const r = f.covering(off, n) orelse {
            c.g_set_error_literal(err, quark(), WOULD_BLOCK, "Offset not written to file yet");
            return 0;
        };
        var got: usize = 0;
        if (f.fp) |fp| {
            if (f.pos != off) {
                if (!f.seek(off)) return readError(fp, 0, err);
            } else if (f.writing) _ = c.fflush(fp);
            f.writing = false;
            got = c.fread(data, 1, n, fp);
            if (got < n) return readError(fp, got, err);
        }
        f.pos = off + got;
        if (remaining) |x| x.* = r.stop - f.pos;
        return n;
    }

    fn readError(fp: *c.FILE, got: usize, err: [*c][*c]c.GError) usize {
        if (c.ferror(fp) != 0) {
            fail(err, "reading");
            return 0;
        }
        if (c.feof(fp) != 0) {
            if (got == 0) c.g_set_error_literal(err, quark(), E.FAILED, "Error reading file: EOF");
            return got;
        }
        c.g_set_error_literal(err, quark(), E.FAILED, "Error reading file");
        return 0;
    }

    pub fn before(f: *File, off: usize) ?Range {
        var found: ?Range = null;
        for (f.ranges.items) |r| {
            if (r.start > off) break;
            found = r;
        }
        return found;
    }

    pub fn after(f: *File, off: usize) ?Range {
        for (f.ranges.items) |r| {
            if (r.stop > off) return r;
        }
        return null;
    }
};

fn code(e: c_int) c.gint {
    return switch (e) {
        c.EEXIST => E.EXISTS,
        c.EISDIR => E.IS_DIRECTORY,
        c.EACCES, c.EPERM => E.PERMISSION_DENIED,
        c.ENAMETOOLONG => E.FILENAME_TOO_LONG,
        c.ENOENT => E.NOT_FOUND,
        c.ENOTDIR => E.NOT_DIRECTORY,
        c.EROFS => E.READ_ONLY,
        c.ELOOP => E.TOO_MANY_LINKS,
        c.ENOSPC, c.ENOMEM => E.NO_SPACE,
        c.EINVAL => E.INVALID_ARGUMENT,
        c.ECANCELED => E.CANCELLED,
        c.ENOTEMPTY => E.NOT_EMPTY,
        c.ENOTSUP, c.EPROTONOSUPPORT, c.ESOCKTNOSUPPORT, c.EPFNOSUPPORT, c.EAFNOSUPPORT => E.NOT_SUPPORTED,
        c.ETIMEDOUT => E.TIMED_OUT,
        c.EBUSY => E.BUSY,
        c.EWOULDBLOCK => E.WOULD_BLOCK,
        c.EMFILE => E.TOO_MANY_OPEN_FILES,
        c.EADDRINUSE => E.ADDRESS_IN_USE,
        c.EHOSTUNREACH => E.HOST_UNREACHABLE,
        c.ENETUNREACH => E.NETWORK_UNREACHABLE,
        c.ECONNREFUSED => E.CONNECTION_REFUSED,
        c.EPIPE => E.BROKEN_PIPE,
        else => E.FAILED,
    };
}
