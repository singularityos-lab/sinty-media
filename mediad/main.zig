const std = @import("std");
const c = @import("c").c;
const S = @import("sys.zig").s;
const proto = @import("proto.zig");

const SLOTS = 8;
const LIMIT = 4;
const SEATS = 64;
const gpa = std.heap.c_allocator;

const Slot = struct {
    id: i64,
    fd: c_int,
    size: usize,
    map: [*]u8,
    busy: bool,
};

const Held = struct {
    slot: ?usize,
    buffer: ?*c.GstBuffer,
    seats: u64,
};

const Client = struct {
    fd: c_int,
    session: ?*Session = null,
    seat: usize = 0,
    caps: ?[*:0]u8 = null,
    known: [SLOTS]i64 = .{-1} ** SLOTS,
    outstanding: u32 = 0,
    watch: c.guint = 0,
};

const Session = struct {
    key: []u8,
    pipeline: *c.GstElement,
    live: bool,
    seats: [SEATS]?*Client = .{null} ** SEATS,
    count: usize = 0,
    lock: c.GMutex = undefined,
    cond: c.GCond = undefined,
    slots: [SLOTS]?Slot = .{null} ** SLOTS,
    held: std.AutoHashMapUnmanaged(u64, Held) = .empty,
    next_id: u64 = 1,
    next_slot: i64 = 1,
    closing: bool = false,
    bus_watch: c.guint = 0,
};

var sessions: std.ArrayListUnmanaged(*Session) = .empty;
var loop: ?*c.GMainLoop = null;
var worker = false;
var self_path: [4096]u8 = undefined;
var cat: ?*c.GstDebugCategory = null;

fn note(comptime fmt: [*:0]const u8, arg: [*c]const u8) void {
    c.gst_debug_log(cat, c.GST_LEVEL_INFO, "mediad/main.zig", "sinty-mediad", 0, null, fmt, arg);
}

fn failure(fd: c_int, domain: [*c]const u8, code: c_int, message: [*c]const u8, debug: [*c]const u8) void {
    var f = proto.Failure{ .domain = 0, .code = code };
    const z = [_]u8{0};
    _ = proto.send(fd, .failure, &.{ std.mem.asBytes(&f), std.mem.span(domain), &z, std.mem.span(message), &z, if (debug != null) std.mem.span(debug) else "", &z }, -1, false);
}

fn slotFor(s: *Session, need: usize) ?usize {
    var spare: ?usize = null;
    for (&s.slots, 0..) |*o, i| {
        if (o.*) |*sl| {
            if (!sl.busy and sl.size >= need) return i;
            if (!sl.busy and spare == null) spare = i;
        } else if (spare == null) spare = i;
    }
    const i = spare orelse return null;
    if (s.slots[i]) |sl| {
        _ = S.munmap(sl.map, sl.size);
        _ = S.close(sl.fd);
        s.slots[i] = null;
    }
    const size = std.mem.alignForward(usize, need, 4096);
    const fd = S.memfd_create("sinty-media", S.MFD_CLOEXEC | S.MFD_ALLOW_SEALING);
    if (fd < 0) return null;
    if (S.ftruncate(fd, @intCast(size)) != 0) {
        _ = S.close(fd);
        return null;
    }
    const m = S.mmap(null, size, S.PROT_READ | S.PROT_WRITE, S.MAP_SHARED, fd, 0);
    if (m == S.MAP_FAILED) {
        _ = S.close(fd);
        return null;
    }
    s.slots[i] = .{ .id = s.next_slot, .fd = fd, .size = size, .map = @ptrCast(m), .busy = false };
    s.next_slot += 1;
    return i;
}

fn dropHeld(s: *Session, h: Held) void {
    if (h.slot) |i| {
        if (s.slots[i]) |*sl| sl.busy = false;
    }
    if (h.buffer) |b| c.gst_buffer_unref(b);
}

fn sendCaps(cl: *Client, caps: [*c]c.GstCaps) bool {
    const str = c.gst_caps_to_string(caps);
    defer c.g_free(str);
    if (cl.caps) |old| {
        if (std.mem.orderZ(u8, old, @ptrCast(str)) == .eq) return true;
        c.g_free(old);
        cl.caps = null;
    }
    const z = [_]u8{0};
    if (!proto.send(cl.fd, .caps, &.{ std.mem.span(@as([*:0]u8, @ptrCast(str))), &z }, -1, false)) return false;
    cl.caps = @ptrCast(c.g_strdup(str));
    return true;
}

fn onSample(sink: ?*c.GstAppSink, data: c.gpointer) callconv(.c) c.GstFlowReturn {
    const s: *Session = @ptrCast(@alignCast(data));
    const sample = c.gst_app_sink_pull_sample(sink) orelse return c.GST_FLOW_OK;
    defer c.gst_sample_unref(sample);
    const buf = c.gst_sample_get_buffer(sample);
    const caps = c.gst_sample_get_caps(sample);
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    if (s.closing) return c.GST_FLOW_FLUSHING;
    if (s.count == 0) return c.GST_FLOW_OK;
    var frame = std.mem.zeroes(proto.Frame);
    frame.id = s.next_id;
    s.next_id += 1;
    frame.pts = buf[0].pts;
    frame.dts = buf[0].dts;
    frame.duration = buf[0].duration;
    frame.buffer_flags = buf[0].mini_object.flags;
    var held = Held{ .slot = null, .buffer = null, .seats = 0 };
    var pass: c_int = -1;
    const mem = if (c.gst_buffer_n_memory(buf) == 1) c.gst_buffer_peek_memory(buf, 0) else null;
    if (mem != null and c.gst_is_fd_memory(mem) != 0) {
        pass = c.gst_fd_memory_get_fd(mem);
        frame.slot = -1;
        if (c.gst_is_dmabuf_memory(mem) != 0) frame.flags |= proto.FLAG_DMABUF;
        frame.offset = mem[0].offset;
        frame.size = mem[0].size;
        frame.maxsize = mem[0].maxsize;
        held.buffer = c.gst_buffer_ref(buf);
    } else {
        const need = c.gst_buffer_get_size(buf);
        var idx = slotFor(s, @max(need, 1));
        while (idx == null and !s.live and !s.closing) {
            c.g_cond_wait(&s.cond, &s.lock);
            idx = slotFor(s, @max(need, 1));
        }
        if (s.closing) return c.GST_FLOW_FLUSHING;
        const i = idx orelse return c.GST_FLOW_OK;
        const sl = &s.slots[i].?;
        _ = c.gst_buffer_extract(buf, 0, sl.map, need);
        sl.busy = true;
        held.slot = i;
        frame.slot = sl.id;
        frame.size = need;
        frame.maxsize = sl.size;
    }
    for (&s.seats, 0..) |*o, seat| {
        const cl = o.* orelse continue;
        while (!s.live and cl.outstanding >= LIMIT and !s.closing and s.seats[seat] == cl) c.g_cond_wait(&s.cond, &s.lock);
        if (s.closing) break;
        if (s.seats[seat] != cl) continue;
        if (cl.outstanding >= LIMIT) continue;
        if (!sendCaps(cl, caps)) continue;
        var fd = pass;
        if (held.slot) |i| fd = if (cl.known[i] == frame.slot) -1 else s.slots[i].?.fd;
        if (!proto.send(cl.fd, .frame, &.{std.mem.asBytes(&frame)}, fd, s.live)) continue;
        if (held.slot) |i| cl.known[i] = frame.slot;
        cl.outstanding += 1;
        held.seats |= @as(u64, 1) << @intCast(seat);
    }
    if (held.seats == 0 or s.closing) {
        dropHeld(s, held);
        return if (s.closing) c.GST_FLOW_FLUSHING else c.GST_FLOW_OK;
    }
    s.held.put(gpa, frame.id, held) catch dropHeld(s, held);
    return c.GST_FLOW_OK;
}

fn onEos(_: ?*c.GstAppSink, _: c.gpointer) callconv(.c) void {}

fn broadcast(s: *Session, kind: proto.Kind) void {
    c.g_mutex_lock(&s.lock);
    for (s.seats) |o| {
        if (o) |cl| _ = proto.send(cl.fd, kind, &.{}, -1, false);
    }
    c.g_mutex_unlock(&s.lock);
}

fn onBus(_: ?*c.GstBus, msg: [*c]c.GstMessage, data: c.gpointer) callconv(.c) c.gboolean {
    const s: *Session = @ptrCast(@alignCast(data));
    switch (msg[0].type) {
        c.GST_MESSAGE_EOS => broadcast(s, .eos),
        c.GST_MESSAGE_ERROR => {
            var e: [*c]c.GError = null;
            var dbg: [*c]u8 = null;
            c.gst_message_parse_error(msg, &e, &dbg);
            c.g_mutex_lock(&s.lock);
            for (s.seats) |o| {
                if (o) |cl| failure(cl.fd, c.g_quark_to_string(e[0].domain), e[0].code, e[0].message, dbg);
            }
            c.g_mutex_unlock(&s.lock);
            c.g_clear_error(&e);
            c.g_free(dbg);
        },
        else => {},
    }
    return 1;
}

fn build(source: []const u8, filter: []const u8, err: [*c][*c]c.GError) ?*c.GstElement {
    const src_z = gpa.dupeZ(u8, source) catch return null;
    defer gpa.free(src_z);
    const bin = c.gst_parse_bin_from_description(src_z.ptr, 1, err) orelse return null;
    const pipe = c.gst_pipeline_new("sinty-mediad");
    const sink = c.gst_element_factory_make("appsink", "out");
    if (sink == null) {
        c.gst_object_unref(pipe);
        c.gst_object_unref(bin);
        return null;
    }
    _ = c.gst_bin_add(@ptrCast(pipe), @ptrCast(bin));
    _ = c.gst_bin_add(@ptrCast(pipe), sink);
    if (filter.len != 0) {
        const fz = gpa.dupeZ(u8, filter) catch return null;
        defer gpa.free(fz);
        const caps = c.gst_caps_from_string(fz.ptr);
        if (caps != null) {
            c.gst_app_sink_set_caps(@ptrCast(sink), caps);
            c.gst_caps_unref(caps);
        }
    }
    c.g_object_set(sink, "sync", @as(c.gboolean, 0), "enable-last-sample", @as(c.gboolean, 0), @as(?*anyopaque, null));
    if (c.gst_element_link(@ptrCast(bin), sink) == 0) {
        c.g_set_error_literal(err, c.gst_core_error_quark(), c.GST_CORE_ERROR_NEGOTIATION, "could not link the delegated source");
        c.gst_object_unref(pipe);
        return null;
    }
    return pipe;
}

fn popError(pipe: *c.GstElement, cl: *Client) void {
    const bus = c.gst_element_get_bus(pipe);
    defer c.gst_object_unref(bus);
    const msg = c.gst_bus_pop_filtered(bus, c.GST_MESSAGE_ERROR);
    if (msg == null) {
        failure(cl.fd, "gst-core-error-quark", c.GST_CORE_ERROR_STATE_CHANGE, "the delegated source failed to start", null);
        return;
    }
    defer c.gst_message_unref(msg);
    var e: [*c]c.GError = null;
    var dbg: [*c]u8 = null;
    c.gst_message_parse_error(msg, &e, &dbg);
    failure(cl.fd, c.g_quark_to_string(e[0].domain), e[0].code, e[0].message, dbg);
    c.g_clear_error(&e);
    c.g_free(dbg);
}

fn startSession(key: []u8, source: []const u8, filter: []const u8, cl: *Client) ?*Session {
    var err: [*c]c.GError = null;
    const pipe = build(source, filter, &err) orelse {
        if (err != null) {
            failure(cl.fd, c.g_quark_to_string(err[0].domain), err[0].code, err[0].message, null);
            c.g_clear_error(&err);
        } else failure(cl.fd, "gst-core-error-quark", c.GST_CORE_ERROR_MISSING_PLUGIN, "could not build the delegated source", null);
        gpa.free(key);
        return null;
    };
    const s = gpa.create(Session) catch {
        gpa.free(key);
        return null;
    };
    s.* = .{ .key = key, .pipeline = pipe, .live = false };
    c.g_mutex_init(&s.lock);
    c.g_cond_init(&s.cond);
    const sink = c.gst_bin_get_by_name(@ptrCast(pipe), "out");
    var cbs = std.mem.zeroes(c.GstAppSinkCallbacks);
    cbs.new_sample = onSample;
    cbs.eos = onEos;
    c.gst_app_sink_set_callbacks(@ptrCast(sink), &cbs, s, null);
    c.gst_object_unref(sink);
    const bus = c.gst_element_get_bus(pipe);
    s.bus_watch = c.gst_bus_add_watch(bus, onBus, s);
    c.gst_object_unref(bus);
    const r = c.gst_element_set_state(pipe, c.GST_STATE_PAUSED);
    if (r == c.GST_STATE_CHANGE_FAILURE) {
        popError(pipe, cl);
        destroy(s);
        return null;
    }
    s.live = r == c.GST_STATE_CHANGE_NO_PREROLL;
    sessions.append(gpa, s) catch {};
    note("session started: %s", @ptrCast(key.ptr));
    return s;
}

fn destroy(s: *Session) void {
    note("session stopped: %s", @ptrCast(s.key.ptr));
    c.g_mutex_lock(&s.lock);
    s.closing = true;
    c.g_cond_broadcast(&s.cond);
    c.g_mutex_unlock(&s.lock);
    _ = c.gst_element_set_state(s.pipeline, c.GST_STATE_NULL);
    if (s.bus_watch != 0) _ = c.g_source_remove(s.bus_watch);
    c.gst_object_unref(s.pipeline);
    var it = s.held.valueIterator();
    while (it.next()) |h| dropHeld(s, h.*);
    s.held.deinit(gpa);
    for (s.slots) |o| {
        if (o) |sl| {
            _ = S.munmap(sl.map, sl.size);
            _ = S.close(sl.fd);
        }
    }
    for (sessions.items, 0..) |x, i| {
        if (x == s) {
            _ = sessions.swapRemove(i);
            break;
        }
    }
    c.g_mutex_clear(&s.lock);
    c.g_cond_clear(&s.cond);
    gpa.free(s.key);
    gpa.destroy(s);
}

fn leave(cl: *Client) void {
    const s = cl.session orelse return;
    cl.session = null;
    c.g_mutex_lock(&s.lock);
    s.seats[cl.seat] = null;
    s.count -= 1;
    const bit = @as(u64, 1) << @intCast(cl.seat);
    var dead: std.ArrayListUnmanaged(u64) = .empty;
    var it = s.held.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seats & bit != 0) {
            e.value_ptr.seats &= ~bit;
            if (e.value_ptr.seats == 0) dead.append(gpa, e.key_ptr.*) catch {};
        }
    }
    for (dead.items) |id| {
        if (s.held.fetchRemove(id)) |kv| dropHeld(s, kv.value);
    }
    dead.deinit(gpa);
    c.g_cond_broadcast(&s.cond);
    const empty = s.count == 0;
    c.g_mutex_unlock(&s.lock);
    if (empty) destroy(s);
}

fn drop(cl: *Client) void {
    leave(cl);
    if (cl.watch != 0) _ = c.g_source_remove(cl.watch);
    _ = S.close(cl.fd);
    if (cl.caps) |p| c.g_free(p);
    gpa.destroy(cl);
    if (worker) c.g_main_loop_quit(loop);
}

fn release(cl: *Client, id: u64) void {
    const s = cl.session orelse return;
    c.g_mutex_lock(&s.lock);
    defer c.g_mutex_unlock(&s.lock);
    const bit = @as(u64, 1) << @intCast(cl.seat);
    const h = s.held.getPtr(id) orelse return;
    if (h.seats & bit == 0) return;
    h.seats &= ~bit;
    if (cl.outstanding > 0) cl.outstanding -= 1;
    if (h.seats == 0) {
        if (s.held.fetchRemove(id)) |kv| dropHeld(s, kv.value);
    }
    c.g_cond_broadcast(&s.cond);
}

fn spawnWorker(cl: *Client, body: []const u8) void {
    const pid = S.fork();
    if (pid == 0) {
        _ = S.dup2(cl.fd, 3);
        var hex: [proto.MAX * 2 + 1]u8 = undefined;
        const enc = std.fmt.bufPrintZ(&hex, "{x}", .{body}) catch S._exit(1);
        const argv = [_:null]?[*:0]const u8{ "sinty-mediad", "--worker", enc.ptr, null };
        _ = S.execv(@ptrCast(&self_path), @ptrCast(&argv));
        S._exit(127);
    }
    if (pid < 0) failure(cl.fd, "gst-resource-error-quark", c.GST_RESOURCE_ERROR_FAILED, "could not start the isolated worker", null);
}

fn open(cl: *Client, body: []const u8) bool {
    if (cl.session != null or body.len < 4) return false;
    const flags = std.mem.readInt(u32, body[0..4], .little);
    var parts: [2][]const u8 = .{ "", "" };
    if (proto.strings(body[4..], &parts) < 2) return false;
    if (flags & proto.FLAG_ISOLATED != 0 and !worker) {
        spawnWorker(cl, body);
        return false;
    }
    const key = std.fmt.allocPrintSentinel(gpa, "{s}\x01{s}", .{ parts[0], parts[1] }, 0) catch return false;
    var s: ?*Session = null;
    for (sessions.items) |x| {
        if (std.mem.eql(u8, x.key, key)) s = x;
    }
    if (s) |found| {
        gpa.free(key);
        if (found.count >= SEATS) {
            failure(cl.fd, "gst-resource-error-quark", c.GST_RESOURCE_ERROR_BUSY, "too many clients on this source", null);
            return false;
        }
    } else s = startSession(key, parts[0], parts[1], cl) orelse return false;
    const ss = s.?;
    c.g_mutex_lock(&ss.lock);
    for (&ss.seats, 0..) |*o, i| {
        if (o.* == null) {
            o.* = cl;
            cl.seat = i;
            break;
        }
    }
    ss.count += 1;
    cl.session = ss;
    c.g_mutex_unlock(&ss.lock);
    var ready: u32 = if (ss.live) proto.FLAG_LIVE else 0;
    _ = proto.send(cl.fd, .ready, &.{std.mem.asBytes(&ready)}, -1, false);
    if (ss.count == 1) _ = c.gst_element_set_state(ss.pipeline, c.GST_STATE_PLAYING);
    return true;
}

fn onClient(fd: c_int, cond: c.GIOCondition, data: c.gpointer) callconv(.c) c.gboolean {
    const cl: *Client = @ptrCast(@alignCast(data));
    if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0 and cond & c.G_IO_IN == 0) {
        cl.watch = 0;
        drop(cl);
        return 0;
    }
    var buf: [proto.MAX]u8 = undefined;
    const m = proto.recv(fd, &buf) orelse {
        cl.watch = 0;
        drop(cl);
        return 0;
    };
    if (m.fd >= 0) _ = S.close(m.fd);
    const keep = switch (m.kind) {
        .open => open(cl, m.body),
        .release => blk: {
            if (proto.asStruct(u64, m.body)) |id| release(cl, id);
            break :blk true;
        },
        else => false,
    };
    if (!keep) {
        cl.watch = 0;
        drop(cl);
        return 0;
    }
    return 1;
}

fn addClient(fd: c_int) void {
    const cl = gpa.create(Client) catch {
        _ = S.close(fd);
        return;
    };
    cl.* = .{ .fd = fd };
    cl.watch = c.g_unix_fd_add(fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, onClient, cl);
}

fn onListen(fd: c_int, _: c.GIOCondition, _: c.gpointer) callconv(.c) c.gboolean {
    const cfd = proto.acceptOn(fd, null, null, S.SOCK_CLOEXEC);
    if (cfd >= 0) addClient(cfd);
    return 1;
}

fn onSignal(_: c.gpointer) callconv(.c) c.gboolean {
    c.g_main_loop_quit(loop);
    return 0;
}

fn writeFile(path: [*:0]const u8, data: []const u8) bool {
    const fd = S.open(path, S.O_WRONLY | S.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = S.close(fd);
    return S.write(fd, data.ptr, data.len) == data.len;
}

fn sandbox() void {
    _ = S.prctl(S.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
    const uid = S.getuid();
    const gid = S.getgid();
    if (S.unshare(S.CLONE_NEWUSER | S.CLONE_NEWNET) != 0) {
        c.g_log("sinty-mediad", c.G_LOG_LEVEL_WARNING, "worker runs without a private network namespace");
        return;
    }
    var buf: [64]u8 = undefined;
    _ = writeFile("/proc/self/setgroups", "deny");
    _ = writeFile("/proc/self/uid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ uid, uid }) catch return);
    _ = writeFile("/proc/self/gid_map", std.fmt.bufPrint(&buf, "{d} {d} 1", .{ gid, gid }) catch return);
}

fn listen() c_int {
    var pbuf: [512]u8 = undefined;
    const path = proto.socketPath(&pbuf) orelse return -1;
    const probe = proto.connect(path);
    if (probe >= 0) {
        _ = S.close(probe);
        return -2;
    }
    _ = S.unlink(path);
    const fd = S.socket(S.AF_UNIX, S.SOCK_SEQPACKET | S.SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    var addr = std.mem.zeroes(S.struct_sockaddr_un);
    addr.sun_family = S.AF_UNIX;
    if (path.len >= addr.sun_path.len) return -1;
    @memcpy(addr.sun_path[0..path.len], path);
    const old = S.umask(0o077);
    defer _ = S.umask(old);
    if (proto.bindTo(fd, &addr, @sizeOf(S.struct_sockaddr_un)) != 0) return -1;
    if (S.listen(fd, 16) != 0) return -1;
    return fd;
}

pub fn main(init: std.process.Init) u8 {
    c.gst_init(null, null);
    cat = c._gst_debug_category_new("sinty-mediad", 0, "session media service");
    const n = S.readlink("/proc/self/exe", &self_path, self_path.len - 1);
    if (n <= 0) return 1;
    self_path[@intCast(n)] = 0;
    _ = S.signal(S.SIGCHLD, S.SIG_IGN);
    loop = c.g_main_loop_new(null, 0);
    const args = init.minimal.args.toSlice(gpa) catch return 1;
    if (args.len > 1) {
        if (!std.mem.eql(u8, args[1], "--worker") or args.len < 3) return 2;
        const enc = args[2];
        var body: [proto.MAX]u8 = undefined;
        const raw = std.fmt.hexToBytes(&body, enc) catch return 2;
        worker = true;
        sandbox();
        const cl = gpa.create(Client) catch return 1;
        cl.* = .{ .fd = 3 };
        if (!open(cl, raw)) {
            _ = S.close(3);
            return 1;
        }
        cl.watch = c.g_unix_fd_add(3, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, onClient, cl);
        c.g_main_loop_run(loop);
        return 0;
    }
    const fd = listen();
    if (fd == -2) return 0;
    if (fd < 0) {
        c.g_log("sinty-mediad", c.G_LOG_LEVEL_CRITICAL, "could not listen on the session socket");
        return 1;
    }
    _ = c.g_unix_fd_add(fd, c.G_IO_IN, onListen, null);
    _ = c.g_unix_signal_add(S.SIGTERM, onSignal, null);
    _ = c.g_unix_signal_add(S.SIGINT, onSignal, null);
    c.g_main_loop_run(loop);
    var pbuf: [512]u8 = undefined;
    if (proto.socketPath(&pbuf)) |p| _ = S.unlink(p);
    return 0;
}
