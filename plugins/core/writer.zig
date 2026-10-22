const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../plugins/elements/gstelements_private.c";
const FUNC = "gst_writev_iovecs";
const IOV_MAX = 1024;

fn errno() c_int {
    return std.c._errno().*;
}

fn once(sink: anytype, fd: c_int, poll: ?*c.GstPoll, vecs: [*]c.struct_iovec, n: usize, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
    written.* = 0;
    const timeout: i64 = @as(i64, timeout_ms) * 1000;
    var start: i64 = if (timeout != 0) c.g_get_monotonic_time() else 0;
    while (true) {
        if (flushing) |f| {
            if (@atomicLoad(c.gboolean, f, .seq_cst) != 0) return c.GST_FLOW_FLUSHING;
        }
        if (poll) |p| {
            var r: c_int = 0;
            while (true) {
                r = c.gst_poll_wait(p, cm.CLOCK_NONE);
                if (!(r == -1 and (errno() == c.EINTR or errno() == c.EAGAIN))) break;
            }
            if (r == -1) {
                if (errno() == c.EBUSY) return c.GST_FLOW_FLUSHING;
                cm.elementError(sink, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, null, c.g_strdup_printf("select on file descriptor: %s", c.g_strerror(errno())), FILE, FUNC, 347);
                return c.GST_FLOW_ERROR;
            }
        }
        var r: isize = undefined;
        while (true) {
            r = c.writev(fd, vecs, @intCast(n));
            if (!(r < 0 and errno() == c.EINTR)) break;
        }
        if (r > 0) {
            written.* = @intCast(r);
            return c.GST_FLOW_OK;
        }
        const e = errno();
        if (e == c.EAGAIN or e == c.EWOULDBLOCK or r == 0) {
            if (timeout != 0) start = c.g_get_monotonic_time();
        } else if (e == c.EACCES and timeout > 0) {
            if (c.g_get_monotonic_time() > start + timeout) return writeError(sink, fd);
            c.g_usleep(10000);
            const s = c.lseek(fd, @bitCast(pos), c.SEEK_SET);
            if (s < 0 or @as(u64, @bitCast(s)) != pos) return writeError(sink, fd);
        } else return writeError(sink, fd);
        if (poll != null) c.g_usleep(1000);
    }
}

fn writeError(sink: anytype, fd: c_int) c.GstFlowReturn {
    if (errno() == c.ENOSPC) {
        cm.elementError(sink, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NO_SPACE_LEFT, null, null, FILE, FUNC, 364);
    } else {
        cm.elementError(sink, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, null, c.g_strdup_printf("Error while writing to file descriptor %d: %s", fd, c.g_strerror(errno())), FILE, FUNC, 367);
    }
    return c.GST_FLOW_ERROR;
}

fn advance(vecs: *[*]c.struct_iovec, n: *usize, by: u64) void {
    var w = by;
    while (n.* > 0 and w >= vecs.*[0].iov_len) {
        w -= vecs.*[0].iov_len;
        vecs.* += 1;
        n.* -= 1;
    }
    if (n.* > 0 and w > 0) {
        vecs.*[0].iov_len -= w;
        vecs.*[0].iov_base = @ptrCast(@as([*]u8, @ptrCast(vecs.*[0].iov_base)) + w);
    }
    while (n.* > 0 and vecs.*[0].iov_len == 0) {
        vecs.* += 1;
        n.* -= 1;
    }
}

fn writeAll(sink: anytype, fd: c_int, poll: ?*c.GstPoll, vecs_in: [*]c.struct_iovec, n_in: usize, skip: u64, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
    var vecs = vecs_in;
    var n = n_in;
    advance(&vecs, &n, skip);
    while (n > 0) {
        var w: u64 = 0;
        const r = once(sink, fd, poll, vecs, n, &w, timeout_ms, pos, flushing);
        if (r != c.GST_FLOW_OK) return r;
        written.* += w;
        advance(&vecs, &n, w);
    }
    return c.GST_FLOW_OK;
}

pub fn mem(sink: anytype, fd: c_int, poll: ?*c.GstPoll, data: [*]const u8, size: usize, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
    var v = [1]c.struct_iovec{.{ .iov_base = @constCast(data), .iov_len = size }};
    return writeAll(sink, fd, poll, &v, 1, 0, written, timeout_ms, pos, flushing);
}

const Batch = struct {
    vecs: [IOV_MAX]c.struct_iovec = undefined,
    maps: [IOV_MAX]c.GstMapInfo = undefined,
    n: usize = 0,

    fn add(self: *Batch, m: [*c]c.GstMemory) void {
        if (c.gst_memory_map(m, &self.maps[self.n], c.GST_MAP_READ) != 0) {
            self.vecs[self.n] = .{ .iov_base = self.maps[self.n].data, .iov_len = self.maps[self.n].size };
        } else {
            self.maps[self.n].memory = null;
            self.vecs[self.n] = .{ .iov_base = @constCast(@as([*]const u8, "")), .iov_len = 0 };
        }
        self.n += 1;
    }

    fn flush(self: *Batch, sink: anytype, fd: c_int, poll: ?*c.GstPoll, skip: *u64, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
        var total: u64 = 0;
        for (self.vecs[0..self.n]) |v| total += v.iov_len;
        const r = if (skip.* >= total) c.GST_FLOW_OK else writeAll(sink, fd, poll, &self.vecs, self.n, skip.*, written, timeout_ms, pos, flushing);
        skip.* -|= total;
        self.release();
        return r;
    }

    fn release(self: *Batch) void {
        for (self.maps[0..self.n]) |*m| {
            if (m.memory != null) c.gst_memory_unmap(m.memory, m);
        }
        self.n = 0;
    }
};

pub fn buffer(sink: anytype, fd: c_int, poll: ?*c.GstPoll, b: [*c]c.GstBuffer, skip: u64, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
    const batch = std.heap.c_allocator.create(Batch) catch return c.GST_FLOW_ERROR;
    defer std.heap.c_allocator.destroy(batch);
    batch.* = .{};
    const n = c.gst_buffer_n_memory(b);
    var i: c.guint = 0;
    while (i < n) : (i += 1) batch.add(c.gst_buffer_peek_memory(b, i));
    const r = writeAll(sink, fd, poll, &batch.vecs, batch.n, skip, written, timeout_ms, pos, flushing);
    batch.release();
    return r;
}

pub fn list(sink: anytype, fd: c_int, poll: ?*c.GstPoll, l: ?*c.GstBufferList, skip_in: u64, written: *u64, timeout_ms: c.gint, pos: u64, flushing: ?*c.gboolean) c.GstFlowReturn {
    const batch = std.heap.c_allocator.create(Batch) catch return c.GST_FLOW_ERROR;
    defer std.heap.c_allocator.destroy(batch);
    batch.* = .{};
    var skip = skip_in;
    const nb = c.gst_buffer_list_length(l);
    var i: c.guint = 0;
    while (i < nb) : (i += 1) {
        const b = c.gst_buffer_list_get(l, i);
        const nm = c.gst_buffer_n_memory(b);
        var j: c.guint = 0;
        while (j < nm) : (j += 1) {
            if (batch.n == IOV_MAX) {
                const r = batch.flush(sink, fd, poll, &skip, written, timeout_ms, pos, flushing);
                if (r != c.GST_FLOW_OK) return r;
            }
            batch.add(c.gst_buffer_peek_memory(b, j));
        }
    }
    return batch.flush(sink, fd, poll, &skip, written, timeout_ms, pos, flushing);
}
