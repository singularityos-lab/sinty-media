const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const proto = @import("mediad");
const S = proto.sys;

const FILE = "sintymediasrc.zig";
const CACHE = 16;

const Prop = enum(c.guint) { source = 1, isolated, socket_path };

const Conn = struct {
    fd: c_int,
    refs: std.atomic.Value(u32),
    lock: c.GMutex,

    fn create(fd: c_int) *Conn {
        const n: *Conn = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Conn))));
        n.fd = fd;
        n.refs = .init(1);
        c.g_mutex_init(&n.lock);
        return n;
    }

    fn ref(n: *Conn) *Conn {
        _ = n.refs.fetchAdd(1, .monotonic);
        return n;
    }

    fn unref(n: *Conn) void {
        if (n.refs.fetchSub(1, .acq_rel) != 1) return;
        _ = S.close(n.fd);
        c.g_mutex_clear(&n.lock);
        c.g_free(n);
    }

    fn send(n: *Conn, kind: proto.Kind, parts: []const []const u8) bool {
        c.g_mutex_lock(&n.lock);
        defer c.g_mutex_unlock(&n.lock);
        return proto.send(n.fd, kind, parts, -1, false);
    }
};

const Release = struct {
    conn: *Conn,
    id: u64,
};

const Cached = extern struct {
    id: i64,
    fd: c_int,
};

const Self = extern struct {
    parent: c.GstPushSrc,
    source: [*c]u8,
    socket_path: [*c]u8,
    isolated: c.gboolean,
    conn: ?*Conn,
    wake: c_int,
    caps: [*c]c.GstCaps,
    live: c.gboolean,
    cache: [CACHE]Cached,
    next: usize,
    fd_alloc: ?*c.GstAllocator,
    dma_alloc: ?*c.GstAllocator,
};

const Class = extern struct {
    parent: c.GstPushSrcClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var quark: c.GQuark = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn srcpad(s: *Self) ?*c.GstPad {
    return s.parent.parent.srcpad;
}

fn fail(s: *Self, domain: c.GQuark, code: c.gint, text: [*c]const u8, debug: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    c.gst_element_message_full(@ptrCast(s), c.GST_MESSAGE_ERROR, domain, code, c.g_strdup(text), if (debug != null) c.g_strdup(debug) else null, FILE, (func ++ "").ptr, line);
}

fn remoteFailure(s: *Self, body: []const u8) void {
    const f = proto.asStruct(proto.Failure, body) orelse return fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_FAILED, "Media service failure", null, "remote_failure", 1);
    var parts: [3][]const u8 = .{ "", "", "" };
    _ = proto.strings(body[@sizeOf(proto.Failure)..], &parts);
    const dom = c.g_strndup(parts[0].ptr, parts[0].len);
    const msg = c.g_strndup(parts[1].ptr, parts[1].len);
    const dbg = c.g_strndup(parts[2].ptr, parts[2].len);
    const q = c.g_quark_from_string(dom);
    c.gst_element_message_full(@ptrCast(s), c.GST_MESSAGE_ERROR, q, f.code, msg, if (parts[2].len != 0) dbg else blk: {
        c.g_free(dbg);
        break :blk null;
    }, FILE, "remote_failure", 1);
    c.g_free(dom);
}

const Wait = enum { ready, woken, gone };

fn wait(s: *Self, timeout: c_int) Wait {
    const conn = s.conn orelse return .gone;
    var fds = [2]S.struct_pollfd{ .{ .fd = conn.fd, .events = S.POLLIN, .revents = 0 }, .{ .fd = s.wake, .events = S.POLLIN, .revents = 0 } };
    while (true) {
        const n = S.poll(&fds, 2, timeout);
        if (n < 0 and std.c._errno().* == S.EINTR) continue;
        if (n <= 0) return .gone;
        if (fds[1].revents & S.POLLIN != 0) return .woken;
        return .ready;
    }
}

fn cacheFd(s: *Self, id: i64, fd: c_int) void {
    for (&s.cache) |*e| {
        if (e.id == id) {
            if (e.fd >= 0) _ = S.close(e.fd);
            e.fd = fd;
            return;
        }
    }
    const e = &s.cache[s.next];
    if (e.fd >= 0) _ = S.close(e.fd);
    e.* = .{ .id = id, .fd = fd };
    s.next = (s.next + 1) % CACHE;
}

fn cachedFd(s: *Self, id: i64) c_int {
    for (s.cache) |e| {
        if (e.id == id) return e.fd;
    }
    return -1;
}

fn clearCache(s: *Self) void {
    for (&s.cache) |*e| {
        if (e.fd >= 0) _ = S.close(e.fd);
        e.* = .{ .id = 0, .fd = -1 };
    }
    s.next = 0;
}

fn onRelease(data: c.gpointer) callconv(.c) void {
    const r: *Release = @ptrCast(@alignCast(data));
    _ = r.conn.send(.release, &.{std.mem.asBytes(&r.id)});
    r.conn.unref();
    c.g_free(r);
}

fn wrap(s: *Self, f: proto.Frame, passed: c_int) ?*c.GstBuffer {
    var mem: [*c]c.GstMemory = null;
    if (f.slot < 0) {
        if (passed < 0) return null;
        mem = if (f.flags & proto.FLAG_DMABUF != 0) c.gst_dmabuf_allocator_alloc(s.dma_alloc, passed, @intCast(f.maxsize)) else c.gst_fd_allocator_alloc(s.fd_alloc, passed, @intCast(f.maxsize), c.GST_FD_MEMORY_FLAG_NONE);
    } else {
        if (passed >= 0) cacheFd(s, f.slot, passed);
        const fd = cachedFd(s, f.slot);
        if (fd < 0) return null;
        const dup = S.fcntl(fd, S.F_DUPFD_CLOEXEC, @as(c_int, 0));
        if (dup < 0) return null;
        mem = c.gst_fd_allocator_alloc(s.fd_alloc, dup, @intCast(f.maxsize), c.GST_FD_MEMORY_FLAG_NONE);
    }
    if (mem == null) return null;
    c.gst_memory_resize(mem, @intCast(f.offset), @intCast(f.size));
    const b = c.gst_buffer_new();
    c.gst_buffer_append_memory(b, mem);
    b[0].mini_object.flags |= f.buffer_flags & ~@as(c.guint, 0xf);
    b[0].duration = f.duration;
    if (s.live == 0) {
        b[0].pts = f.pts;
        b[0].dts = f.dts;
    }
    const r: *Release = @ptrCast(@alignCast(c.g_malloc(@sizeOf(Release))));
    r.* = .{ .conn = s.conn.?.ref(), .id = f.id };
    c.gst_mini_object_set_qdata(&b[0].mini_object, quark, r, onRelease);
    return b;
}

const Next = union(enum) { caps, frame: *c.GstBuffer, eos, failed, flushing };

fn next(s: *Self) Next {
    var buf: [proto.MAX]u8 = undefined;
    while (true) {
        switch (wait(s, -1)) {
            .woken => return .flushing,
            .gone => return .failed,
            .ready => {},
        }
        const m = proto.recv(s.conn.?.fd, &buf) orelse {
            fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_READ, "Lost the connection to the media service", null, "next", 2);
            return .failed;
        };
        switch (m.kind) {
            .caps => {
                if (m.fd >= 0) _ = S.close(m.fd);
                const str = c.g_strndup(m.body.ptr, m.body.len);
                const caps = c.gst_caps_from_string(str);
                c.g_free(str);
                if (caps == null) continue;
                _ = c.gst_caps_replace(&s.caps, caps);
                c.gst_caps_unref(caps);
                return .caps;
            },
            .frame => {
                const f = proto.asStruct(proto.Frame, m.body) orelse {
                    if (m.fd >= 0) _ = S.close(m.fd);
                    continue;
                };
                if (wrap(s, f, m.fd)) |b| return .{ .frame = b };
                _ = s.conn.?.send(.release, &.{std.mem.asBytes(&f.id)});
            },
            .eos => return .eos,
            .failure => {
                remoteFailure(s, m.body);
                return .failed;
            },
            else => if (m.fd >= 0) {
                _ = S.close(m.fd);
            },
        }
    }
}

fn applyCaps(s: *Self) bool {
    return c.gst_base_src_set_caps(@ptrCast(s), s.caps) != 0;
}

fn negotiate(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    if (s.caps == null) {
        switch (next(s)) {
            .caps => {},
            .frame => |b| c.gst_buffer_unref(b),
            else => return 0,
        }
    }
    return @intFromBool(s.caps != null and applyCaps(s));
}

fn getCaps(bs: [*c]c.GstBaseSrc, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bs);
    const caps = if (s.caps != null) c.gst_caps_ref(s.caps) else c.gst_pad_get_pad_template_caps(srcpad(s));
    if (filter == null) return caps;
    const r = c.gst_caps_intersect_full(filter, caps, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(caps);
    return r;
}

fn create(ps: [*c]c.GstPushSrc, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(ps);
    while (true) {
        switch (next(s)) {
            .caps => if (!applyCaps(s)) return c.GST_FLOW_NOT_NEGOTIATED,
            .frame => |b| {
                out[0] = b;
                return c.GST_FLOW_OK;
            },
            .eos => return c.GST_FLOW_EOS,
            .flushing => return c.GST_FLOW_FLUSHING,
            .failed => return c.GST_FLOW_ERROR,
        }
    }
}

fn unlock(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    const one: u64 = 1;
    _ = S.write(s.wake, &one, 8);
    return 1;
}

fn unlockStop(bs: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    const s = me(bs);
    var v: u64 = 0;
    _ = S.read(s.wake, &v, 8);
    return 1;
}

fn isSeekable(_: [*c]c.GstBaseSrc) callconv(.c) c.gboolean {
    return 0;
}

fn filterString(s: *Self) [*c]u8 {
    const caps = c.gst_pad_peer_query_caps(srcpad(s), null);
    if (caps == null) return c.g_strdup("");
    defer c.gst_caps_unref(caps);
    if (c.gst_caps_is_any(caps) != 0 or c.gst_caps_is_empty(caps) != 0) return c.g_strdup("");
    return c.gst_caps_to_string(caps);
}

fn connect(s: *Self) bool {
    var pbuf: [512]u8 = undefined;
    const path: ?[:0]const u8 = if (s.socket_path != null) std.mem.span(@as([*:0]const u8, @ptrCast(s.socket_path))) else proto.socketPath(&pbuf);
    const p = path orelse {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, "Could not find the media service", "XDG_RUNTIME_DIR is not set", "connect", 3);
        return false;
    };
    if (s.source == null) {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_SETTINGS, "No source set", null, "connect", 4);
        return false;
    }
    const fd = proto.connect(p);
    if (fd < 0) {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, "Could not connect to the media service", p.ptr, "connect", 5);
        return false;
    }
    s.conn = Conn.create(fd);
    const filter = filterString(s);
    defer c.g_free(filter);
    var flags: u32 = if (s.isolated != 0) proto.FLAG_ISOLATED else 0;
    const z = [_]u8{0};
    if (!s.conn.?.send(.open, &.{ std.mem.asBytes(&flags), std.mem.span(@as([*:0]const u8, @ptrCast(s.source))), &z, std.mem.span(@as([*:0]const u8, @ptrCast(filter))), &z })) {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_WRITE, "Could not talk to the media service", null, "connect", 6);
        return false;
    }
    var buf: [proto.MAX]u8 = undefined;
    if (wait(s, 15000) != .ready) {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, "The media service did not answer", null, "connect", 7);
        return false;
    }
    const m = proto.recv(fd, &buf) orelse {
        fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, "The media service closed the connection", null, "connect", 8);
        return false;
    };
    if (m.fd >= 0) _ = S.close(m.fd);
    switch (m.kind) {
        .ready => {
            const f = proto.asStruct(u32, m.body) orelse 0;
            s.live = @intFromBool(f & proto.FLAG_LIVE != 0);
            c.gst_base_src_set_live(@ptrCast(s), s.live);
            c.gst_base_src_set_do_timestamp(@ptrCast(s), s.live);
            return true;
        },
        .failure => remoteFailure(s, m.body),
        else => fail(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_OPEN_READ, "Unexpected answer from the media service", null, "connect", 9),
    }
    return false;
}

fn disconnect(s: *Self) void {
    clearCache(s);
    if (s.conn) |n| {
        _ = n.send(.close, &.{});
        _ = S.shutdown(n.fd, S.SHUT_RDWR);
        n.unref();
        s.conn = null;
    }
    if (s.caps != null) {
        c.gst_caps_unref(s.caps);
        s.caps = null;
    }
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) {
        if (!connect(s)) {
            disconnect(s);
            return c.GST_STATE_CHANGE_FAILURE;
        }
    }
    const r = parent_el.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) disconnect(s);
    return r;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.source) => {
            c.g_free(s.source);
            s.source = c.g_value_dup_string(v);
        },
        @intFromEnum(Prop.isolated) => s.isolated = c.g_value_get_boolean(v),
        @intFromEnum(Prop.socket_path) => {
            c.g_free(s.socket_path);
            s.socket_path = c.g_value_dup_string(v);
        },
        else => cm.warnInvalid(FILE, o, id, spec, 1),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        @intFromEnum(Prop.source) => c.g_value_set_string(v, s.source),
        @intFromEnum(Prop.isolated) => c.g_value_set_boolean(v, s.isolated),
        @intFromEnum(Prop.socket_path) => c.g_value_set_string(v, s.socket_path),
        else => cm.warnInvalid(FILE, o, id, spec, 2),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    disconnect(s);
    _ = S.close(s.wake);
    c.g_free(s.source);
    c.g_free(s.socket_path);
    if (s.fd_alloc) |a| c.gst_object_unref(a);
    if (s.dma_alloc) |a| c.gst_object_unref(a);
    parent_obj.finalize.?(o);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.wake = S.eventfd(0, S.EFD_CLOEXEC | S.EFD_NONBLOCK);
    for (&s.cache) |*e| e.* = .{ .id = 0, .fd = -1 };
    s.fd_alloc = c.gst_fd_allocator_new();
    s.dma_alloc = c.gst_dmabuf_allocator_new();
    c.gst_base_src_set_format(@ptrCast(s), c.GST_FORMAT_TIME);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_obj = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    parent_el = @ptrCast(@alignCast(parent_obj));
    quark = c.g_quark_from_static_string("sinty-media-release");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    c.g_object_class_install_property(oc, @intFromEnum(Prop.source), c.g_param_spec_string("source", "Source", "Pipeline description run by the media service", null, cm.RW | c.GST_PARAM_MUTABLE_READY));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.isolated), c.g_param_spec_boolean("isolated", "Isolated", "Run the source in a separate process without network access", 0, cm.RW | c.GST_PARAM_MUTABLE_READY));
    c.g_object_class_install_property(oc, @intFromEnum(Prop.socket_path), c.g_param_spec_string("socket-path", "Socket path", "Media service socket, the session default when unset", null, cm.RW | c.GST_PARAM_MUTABLE_READY));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "Sinty media service source", "Source", "Receives media from the sinty-mediad session service", "Sinty OS");
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    ec.change_state = changeState;
    const bc: *c.GstBaseSrcClass = @ptrCast(@alignCast(k));
    bc.negotiate = negotiate;
    bc.get_caps = getCaps;
    bc.unlock = unlock;
    bc.unlock_stop = unlockStop;
    bc.is_seekable = isSeekable;
    const pc: *c.GstPushSrcClass = @ptrCast(@alignCast(k));
    pc.create = create;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_push_src_get_type(), "GstSintyMediaSrc", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "sintymediasrc", c.GST_RANK_NONE, getType()) != 0;
}
