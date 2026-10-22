const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const DOMAIN = "GStreamer-Net";

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

pub const NONE: u64 = std.math.maxInt(u64);
pub const SECOND: u64 = 1_000_000_000;

const Packet = c.GstNetTimePacket;
const PACKET_SIZE = 16;
pub const NTP_SIZE = 48;

var addr_api: gtype.Once = .{};
var ctl_api: gtype.Once = .{};
var packet_once: gtype.Once = .{};
var addr_info: ?*const c.GstMetaInfo = null;
var ctl_info: ?*const c.GstMetaInfo = null;
var info_lock: gtype.Lock = .{};

fn isBuffer(b: anytype) bool {
    if (b == null) return false;
    const m: *c.GstMiniObject = @ptrCast(@alignCast(b));
    return m.type == c.gst_buffer_get_type();
}

fn addrInit(m: [*c]c.GstMeta, _: c.gpointer, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const n: *c.GstNetAddressMeta = @ptrCast(@alignCast(m));
    n.addr = null;
    return 1;
}

fn addrTransform(dst: [*c]c.GstBuffer, m: [*c]c.GstMeta, _: [*c]c.GstBuffer, _: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const n: *c.GstNetAddressMeta = @ptrCast(@alignCast(m));
    return @intFromBool(gst_buffer_add_net_address_meta(dst, n.addr) != null);
}

fn addrFree(m: [*c]c.GstMeta, _: [*c]c.GstBuffer) callconv(.c) void {
    const n: *c.GstNetAddressMeta = @ptrCast(@alignCast(m));
    if (n.addr != null) c.g_object_unref(n.addr);
    n.addr = null;
}

pub export fn gst_net_address_meta_api_get_type() c.GType {
    return addr_api.get(struct {
        var tags = [_][*c]const u8{ "origin", null };
        fn f() c.GType {
            return c.gst_meta_api_type_register("GstNetAddressMetaAPI", @ptrCast(&tags));
        }
    }.f);
}

pub export fn gst_net_address_meta_get_info() [*c]const c.GstMetaInfo {
    info_lock.lock();
    defer info_lock.unlock();
    if (addr_info == null) addr_info = c.gst_meta_register(gst_net_address_meta_api_get_type(), "GstNetAddressMeta", @sizeOf(c.GstNetAddressMeta), addrInit, addrFree, addrTransform);
    return addr_info;
}

pub export fn gst_buffer_add_net_address_meta(b: [*c]c.GstBuffer, addr: ?*c.GSocketAddress) [*c]c.GstNetAddressMeta {
    if (!that(isBuffer(b), "gst_buffer_add_net_address_meta", "GST_IS_BUFFER (buffer)")) return null;
    if (!that(gtype.instanceOf(addr, c.g_socket_address_get_type()), "gst_buffer_add_net_address_meta", "G_IS_SOCKET_ADDRESS (addr)")) return null;
    const m: [*c]c.GstNetAddressMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b, gst_net_address_meta_get_info(), null)));
    m.*.addr = @ptrCast(@alignCast(c.g_object_ref(addr)));
    return m;
}

pub export fn gst_buffer_get_net_address_meta(b: [*c]c.GstBuffer) [*c]c.GstNetAddressMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(b, gst_net_address_meta_api_get_type())));
}

fn ctlInit(m: [*c]c.GstMeta, _: c.gpointer, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const n: *c.GstNetControlMessageMeta = @ptrCast(@alignCast(m));
    n.message = null;
    return 1;
}

fn ctlTransform(dst: [*c]c.GstBuffer, m: [*c]c.GstMeta, _: [*c]c.GstBuffer, _: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    const n: *c.GstNetControlMessageMeta = @ptrCast(@alignCast(m));
    return @intFromBool(gst_buffer_add_net_control_message_meta(dst, n.message) != null);
}

fn ctlFree(m: [*c]c.GstMeta, _: [*c]c.GstBuffer) callconv(.c) void {
    const n: *c.GstNetControlMessageMeta = @ptrCast(@alignCast(m));
    if (n.message != null) c.g_object_unref(n.message);
    n.message = null;
}

pub export fn gst_net_control_message_meta_api_get_type() c.GType {
    return ctl_api.get(struct {
        var tags = [_][*c]const u8{ "origin", null };
        fn f() c.GType {
            return c.gst_meta_api_type_register("GstNetControlMessageMetaAPI", @ptrCast(&tags));
        }
    }.f);
}

pub export fn gst_net_control_message_meta_get_info() [*c]const c.GstMetaInfo {
    info_lock.lock();
    defer info_lock.unlock();
    if (ctl_info == null) ctl_info = c.gst_meta_register(gst_net_control_message_meta_api_get_type(), "GstNetControlMessageMeta", @sizeOf(c.GstNetControlMessageMeta), ctlInit, ctlFree, ctlTransform);
    return ctl_info;
}

pub export fn gst_buffer_add_net_control_message_meta(b: [*c]c.GstBuffer, msg: ?*c.GSocketControlMessage) [*c]c.GstNetControlMessageMeta {
    if (!that(isBuffer(b), "gst_buffer_add_net_control_message_meta", "GST_IS_BUFFER (buffer)")) return null;
    if (!that(gtype.instanceOf(msg, c.g_socket_control_message_get_type()), "gst_buffer_add_net_control_message_meta", "G_IS_SOCKET_CONTROL_MESSAGE (message)")) return null;
    const m: [*c]c.GstNetControlMessageMeta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b, gst_net_control_message_meta_get_info(), null)));
    m.*.message = @ptrCast(@alignCast(c.g_object_ref(msg)));
    return m;
}

pub fn be64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .big);
}

pub fn be32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

pub fn put64(p: [*]u8, v: u64) void {
    std.mem.writeInt(u64, p[0..8], v, .big);
}

pub fn put32(p: [*]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .big);
}

fn copyBoxed(p: c.gconstpointer) callconv(.c) c.gpointer {
    return gst_net_time_packet_copy(@ptrCast(@alignCast(p)));
}

fn freeBoxed(p: c.gpointer) callconv(.c) void {
    gst_net_time_packet_free(@ptrCast(@alignCast(p)));
}

pub export fn gst_net_time_packet_get_type() c.GType {
    return packet_once.get(struct {
        fn f() c.GType {
            return gtype.boxed(c.g_intern_static_string("GstNetTimePacket"), copyBoxed, freeBoxed);
        }
    }.f);
}

pub export fn gst_net_time_packet_new(buf: [*c]const u8) [*c]Packet {
    const p: [*c]Packet = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Packet))));
    if (buf != null) {
        p.*.local_time = be64(buf);
        p.*.remote_time = be64(buf + 8);
    } else {
        p.*.local_time = NONE;
        p.*.remote_time = NONE;
    }
    return p;
}

pub export fn gst_net_time_packet_free(p: [*c]Packet) void {
    c.g_free(p);
}

pub export fn gst_net_time_packet_copy(p: [*c]const Packet) [*c]Packet {
    const r: [*c]Packet = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Packet))));
    r.*.local_time = p.*.local_time;
    r.*.remote_time = p.*.remote_time;
    return r;
}

pub export fn gst_net_time_packet_serialize(p: [*c]const Packet) [*c]u8 {
    const r: [*c]u8 = @ptrCast(c.g_malloc0(PACKET_SIZE));
    put64(r, p.*.local_time);
    put64(r + 8, p.*.remote_time);
    return r;
}

pub fn receive(sock: ?*c.GSocket, src: [*c]?*c.GSocketAddress, err: [*c][*c]c.GError, buf: []u8) isize {
    while (true) {
        var e: [*c]c.GError = null;
        const r = c.g_socket_receive_from(sock, @ptrCast(src), @ptrCast(buf.ptr), buf.len, null, &e);
        if (r < 0) {
            if (e.*.code == c.G_IO_ERROR_WOULD_BLOCK) {
                c.g_error_free(e);
                continue;
            }
            c.g_propagate_error(err, e);
            return -1;
        }
        if (r < buf.len) {
            c.g_set_error(err, c.g_io_error_quark(), c.G_IO_ERROR_INVALID_DATA, "short time packet (%d < %d)", @as(c_int, @intCast(r)), @as(c_int, @intCast(buf.len)));
            return -1;
        }
        return r;
    }
}

pub export fn gst_net_time_packet_receive(sock: ?*c.GSocket, src: [*c]?*c.GSocketAddress, err: [*c][*c]c.GError) [*c]Packet {
    if (!that(gtype.instanceOf(sock, c.g_socket_get_type()), "gst_net_time_packet_receive", "G_IS_SOCKET (socket)")) return null;
    if (!that(err == null or err.* == null, "gst_net_time_packet_receive", "error == NULL || *error == NULL")) return null;
    var buf: [PACKET_SIZE]u8 = undefined;
    if (receive(sock, src, err, &buf) < 0) return null;
    return gst_net_time_packet_new(&buf);
}

pub fn sendTo(sock: ?*c.GSocket, dest: ?*c.GSocketAddress, data: [*c]u8, size: usize, err: [*c][*c]c.GError) bool {
    const blocking = c.g_socket_get_blocking(sock);
    if (blocking != 0) c.g_socket_set_blocking(sock, 0);
    const r = c.g_socket_send_to(sock, dest, @ptrCast(data), size, null, err);
    c.g_free(data);
    if (blocking != 0) c.g_socket_set_blocking(sock, 1);
    return r == @as(isize, @intCast(size));
}

pub export fn gst_net_time_packet_send(p: [*c]const Packet, sock: ?*c.GSocket, dest: ?*c.GSocketAddress, err: [*c][*c]c.GError) c.gboolean {
    const F = "gst_net_time_packet_send";
    if (!that(p != null, F, "packet != NULL")) return 0;
    if (!that(gtype.instanceOf(sock, c.g_socket_get_type()), F, "G_IS_SOCKET (socket)")) return 0;
    if (!that(gtype.instanceOf(dest, c.g_socket_address_get_type()), F, "G_IS_SOCKET_ADDRESS (dest_address)")) return 0;
    if (!that(err == null or err.* == null, F, "error == NULL || *error == NULL")) return 0;
    return @intFromBool(sendTo(sock, dest, gst_net_time_packet_serialize(p), PACKET_SIZE, err));
}

pub export fn gst_net_utils_set_socket_tos(sock: ?*c.GSocket, dscp: c.gint) c.gboolean {
    var ret: c.gboolean = 0;
    const fd = c.g_socket_get_fd(sock);
    var tos: c_int = (dscp & 0x3f) << 2;
    if (c.setsockopt(fd, c.IPPROTO_IP, c.IP_TOS, &tos, @sizeOf(c_int)) >= 0) ret = 1;
    if (c.g_socket_get_family(sock) == c.G_SOCKET_FAMILY_IPV6) {
        if (c.setsockopt(fd, c.IPPROTO_IPV6, c.IPV6_TCLASS, &tos, @sizeOf(c_int)) >= 0) ret = 1;
    }
    return ret;
}

pub const Ntp = struct {
    origin: u64 = 0,
    receive: u64 = 0,
    transmit: u64 = 0,
    poll: u64 = 0,
};

pub const NTP_WRONG_VERSION = 0;
pub const NTP_KOD_DENY = 1;
pub const NTP_KOD_RATE = 2;
pub const NTP_KOD_UNKNOWN = 3;

pub fn ntpQuark() c.GQuark {
    return c.g_quark_from_static_string("gst-ntp-error-quark");
}

fn ntpTime(s: u32, f: u32) u64 {
    return c.gst_util_uint64_scale(s, SECOND, 1) +% c.gst_util_uint64_scale(f, SECOND, @as(u64, 1) << 32);
}

fn ntpSeconds(t: u64) u32 {
    return @truncate(c.gst_util_uint64_scale(t, 1, SECOND));
}

fn ntpFraction(t: u64) u32 {
    const s = c.gst_util_uint64_scale(t, 1, SECOND);
    return @truncate(c.gst_util_uint64_scale(t -% s, @as(u64, 1) << 32, SECOND));
}

pub fn ntpParse(b: [*]const u8, err: [*c][*c]c.GError) ?Ntp {
    const version = (b[0] >> 3) & 7;
    const stratum = b[1];
    const poll: i8 = @bitCast(b[2]);
    if (version != 4) {
        c.g_set_error(err, ntpQuark(), NTP_WRONG_VERSION, "Invalid NTP version %d", @as(c_int, version));
        return null;
    }
    if (stratum == 0) {
        var code = [5]u8{ b[12], b[13], b[14], b[15], 0 };
        const s = std.mem.sliceTo(&code, 0);
        const deny = [_][]const u8{ "AUTH", "AUTO", "CRYP", "DENY", "RSTR", "NKEY" };
        for (deny) |d| {
            if (std.mem.eql(u8, s, d)) {
                c.g_set_error(err, ntpQuark(), NTP_KOD_DENY, "Kiss-o'-Death denied '%s'", &code);
                return null;
            }
        }
        if (std.mem.eql(u8, s, "RATE")) {
            c.g_set_error(err, ntpQuark(), NTP_KOD_RATE, "Kiss-o'-Death '%s'", &code);
        } else c.g_set_error(err, ntpQuark(), NTP_KOD_UNKNOWN, "Kiss-o'-Death unknown '%s'", &code);
        return null;
    }
    var r = Ntp{};
    r.origin = ntpTime(be32(b + 24), be32(b + 28));
    r.receive = ntpTime(be32(b + 32), be32(b + 36));
    r.transmit = ntpTime(be32(b + 40), be32(b + 44));
    if (poll >= 3) {
        r.poll = NONE;
    } else if (poll >= 0) {
        r.poll = SECOND << @intCast(poll);
    } else r.poll = SECOND >> @intCast(-@as(i16, poll));
    return r;
}

pub fn ntpSerialize(p: Ntp) [*c]u8 {
    const r: [*c]u8 = @ptrCast(c.g_malloc0(NTP_SIZE));
    r[0] = (3 << 6) | (4 << 3) | 3;
    r[1] = 16;
    r[2] = 3;
    r[3] = 0;
    put32(r + 24, ntpSeconds(p.origin));
    put32(r + 28, ntpFraction(p.origin));
    put32(r + 32, ntpSeconds(p.receive));
    put32(r + 36, ntpFraction(p.receive));
    put32(r + 40, ntpSeconds(p.transmit));
    put32(r + 44, ntpFraction(p.transmit));
    return r;
}
