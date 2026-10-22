const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

pub const DEFAULT_HOST = "localhost";
pub const DEFAULT_PORT = 4953;
pub const HIGHEST_PORT = 65535;

var init_done: ?*anyopaque = null;

pub fn elementInit() void {
    if (c.g_once_init_enter_pointer(@ptrCast(&init_done)) != 0) {
        _ = c._gst_debug_category_new("tcp", 0, "TCP calls");
        c.g_once_init_leave_pointer(@ptrCast(&init_done), @ptrFromInt(1));
    }
}

pub fn getAddresses(obj: anytype, host: [*c]const u8, cancel: ?*c.GCancellable, err: [*c][*c]c.GError) [*c]c.GList {
    if (!cm.that(cm.isA(@as(?*anyopaque, @ptrCast(obj)), c.gst_element_get_type()), "tcp_get_addresses", "GST_IS_ELEMENT (obj)")) return null;
    if (!cm.that(host != null, "tcp_get_addresses", "host != NULL")) return null;
    const addr = c.g_inet_address_new_from_string(host);
    if (addr != null) return c.g_list_append(null, addr);
    const resolver = c.g_resolver_get_default();
    defer c.g_object_unref(resolver);
    return c.g_resolver_lookup_by_name(resolver, host, cancel, err);
}

pub fn createSocket(obj: anytype, iter: *[*c]c.GList, port: u16, saddr: *?*c.GSocketAddress, err: [*c][*c]c.GError) ?*c.GSocket {
    if (!cm.that(cm.isA(@as(?*anyopaque, @ptrCast(obj)), c.gst_element_get_type()), "tcp_create_socket", "GST_IS_ELEMENT (obj)")) return null;
    saddr.* = null;
    while (iter.* != null) {
        const addr: ?*c.GInetAddress = @ptrCast(@alignCast(iter.*.*.data));
        c.g_clear_error(err);
        iter.* = iter.*.*.next;
        saddr.* = c.g_inet_socket_address_new(addr, port);
        const sock = c.g_socket_new(c.g_socket_address_get_family(saddr.*), c.G_SOCKET_TYPE_STREAM, c.G_SOCKET_PROTOCOL_TCP, err);
        if (sock != null) return sock;
        c.g_object_unref(saddr.*);
        saddr.* = null;
    }
    return null;
}

const TcpInfo = extern struct {
    head: [8]u8,
    tcpi_rto: u32,
    tcpi_ato: u32,
    tcpi_snd_mss: u32,
    tcpi_rcv_mss: u32,
    tcpi_unacked: u32,
    tcpi_sacked: u32,
    tcpi_lost: u32,
    tcpi_retrans: u32,
    tcpi_fackets: u32,
    tcpi_last_data_sent: u32,
    tcpi_last_ack_sent: u32,
    tcpi_last_data_recv: u32,
    tcpi_last_ack_recv: u32,
    tcpi_pmtu: u32,
    tcpi_rcv_ssthresh: u32,
    tcpi_rtt: u32,
    tcpi_rttvar: u32,
    tcpi_snd_ssthresh: u32,
    tcpi_snd_cwnd: u32,
    tcpi_advmss: u32,
    tcpi_reordering: u32,
};

pub fn statsFromSocket(st: ?*c.GstStructure, socket: ?*c.GSocket) void {
    var info = std.mem.zeroes(TcpInfo);
    var len: c.socklen_t = @sizeOf(TcpInfo);
    if (c.getsockopt(c.g_socket_get_fd(socket), c.IPPROTO_TCP, c.TCP_INFO, &info, &len) != 0) return;
    c.gst_structure_set(st, "reordering", c.G_TYPE_UINT, info.tcpi_reordering, "unacked", c.G_TYPE_UINT, info.tcpi_unacked, "sacked", c.G_TYPE_UINT, info.tcpi_sacked, "lost", c.G_TYPE_UINT, info.tcpi_lost, "retrans", c.G_TYPE_UINT, info.tcpi_retrans, "fackets", c.G_TYPE_UINT, info.tcpi_fackets, @as(?*anyopaque, null));
}

pub fn isCancelled(err: [*c]c.GError) bool {
    return c.g_error_matches(err, c.g_io_error_quark(), c.G_IO_ERROR_CANCELLED) != 0;
}

pub fn flagSet(o: anytype, f: c.guint) bool {
    return cm.obj(o).flags & f != 0;
}
