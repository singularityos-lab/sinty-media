const std = @import("std");
const c = @import("c").c;

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

fn str(p: [*c]const u8) []const u8 {
    if (p == null) return "(null)";
    return std.mem.span(p);
}

const SEC: u64 = 1_000_000_000;
const NONE: u64 = std.math.maxInt(u64);

fn logger(domain: [*c]const u8, level: c.GLogLevelFlags, msg: [*c]const u8, _: c.gpointer) callconv(.c) void {
    out("  log {s} {d} {s}", .{ str(domain), level & c.G_LOG_LEVEL_MASK, str(msg) });
}

fn describe(t: c.GType) void {
    out("type {s} parent {s}", .{ str(c.g_type_name(t)), str(c.g_type_name(c.g_type_parent(t))) });
    if (c.g_type_is_a(t, c.G_TYPE_OBJECT) == 0) return;
    const k: *c.GObjectClass = @ptrCast(@alignCast(c.g_type_class_ref(t)));
    var n: c.guint = 0;
    const ps = c.g_object_class_list_properties(k, &n);
    for (0..n) |i| {
        const p = ps[i];
        var dv = std.mem.zeroes(c.GValue);
        _ = c.g_value_init(&dv, p.*.value_type);
        c.g_param_value_set_default(p, &dv);
        const s = c.g_strdup_value_contents(&dv);
        out("  prop {s} {s} flags {x} owner {s} blurb {s} default {s}", .{ str(p.*.name), str(c.g_type_name(p.*.value_type)), p.*.flags, str(c.g_type_name(p.*.owner_type)), str(c.g_param_spec_get_blurb(p)), str(s) });
        c.g_free(s);
        c.g_value_unset(&dv);
    }
    c.g_free(@ptrCast(ps));
    var ni: c.guint = 0;
    const ifs = c.g_type_interfaces(t, &ni);
    for (0..ni) |i| out("  iface {s}", .{str(c.g_type_name(ifs[i]))});
    c.g_free(@ptrCast(ifs));
}

fn packets() void {
    out("packets", .{});
    const p = c.gst_net_time_packet_new(null);
    out(" empty {d} {d}", .{ p.*.local_time, p.*.remote_time });
    var raw = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const q = c.gst_net_time_packet_new(&raw);
    out(" parsed {x} {x}", .{ q.*.local_time, q.*.remote_time });
    const s = c.gst_net_time_packet_serialize(q);
    out(" serialized {x}", .{s[0..16]});
    c.g_free(s);
    const r = c.gst_net_time_packet_copy(q);
    out(" copy {x} {x}", .{ r.*.local_time, r.*.remote_time });
    const b: [*c]c.GstNetTimePacket = @ptrCast(@alignCast(c.g_boxed_copy(c.gst_net_time_packet_get_type(), r)));
    out(" boxed {x}", .{b.*.remote_time});
    c.g_boxed_free(c.gst_net_time_packet_get_type(), b);
    c.gst_net_time_packet_free(p);
    c.gst_net_time_packet_free(q);
    c.gst_net_time_packet_free(r);
}

fn metas() void {
    out("metas", .{});
    const info = c.gst_net_address_meta_get_info();
    out(" addr info {s} api {s} size {d} same {d}", .{ str(c.g_type_name(info.*.type)), str(c.g_type_name(info.*.api)), info.*.size, @intFromBool(info == c.gst_net_address_meta_get_info()) });
    const tags = c.gst_meta_api_type_get_tags(c.gst_net_address_meta_api_get_type());
    out(" addr tags {s} has origin {d}", .{ str(tags[0]), c.gst_meta_api_type_has_tag(c.gst_net_address_meta_api_get_type(), c.g_quark_from_string("origin")) });
    const cinfo = c.gst_net_control_message_meta_get_info();
    out(" ctl info {s} api {s} size {d}", .{ str(c.g_type_name(cinfo.*.type)), str(c.g_type_name(cinfo.*.api)), cinfo.*.size });
    const buf = c.gst_buffer_new_allocate(null, 8, null);
    const inet = c.g_inet_address_new_from_string("10.1.2.3");
    const sa = c.g_inet_socket_address_new(inet, 4242);
    const m = c.gst_buffer_add_net_address_meta(buf, sa);
    out(" add {d} same {d}", .{ @intFromBool(m != null), @intFromBool(m.*.addr == sa) });
    const got = c.gst_buffer_get_net_address_meta(buf);
    out(" get {d}", .{@intFromBool(got == m)});
    const copy = c.gst_buffer_copy(buf);
    const cm = c.gst_buffer_get_net_address_meta(copy);
    const s = c.g_inet_address_to_string(c.g_inet_socket_address_get_address(@ptrCast(cm.*.addr)));
    out(" copied {s}:{d} shared {d}", .{ str(s), c.g_inet_socket_address_get_port(@ptrCast(cm.*.addr)), @intFromBool(cm.*.addr == sa) });
    c.g_free(s);
    out(" add null {d}", .{@intFromBool(c.gst_buffer_add_net_address_meta(buf, null) == null)});
    out(" add to null {d}", .{@intFromBool(c.gst_buffer_add_net_address_meta(null, sa) == null)});
    const credNew: *const fn () callconv(.c) ?*c.GSocketControlMessage = @ptrCast(c.dlsym(null, "g_unix_credentials_message_new").?);
    const cred = credNew();
    const ctl = c.gst_buffer_add_net_control_message_meta(buf, cred);
    out(" ctl add {d} same {d}", .{ @intFromBool(ctl != null), @intFromBool(ctl.*.message == cred) });
    const copy2 = c.gst_buffer_copy(buf);
    var it: c.gpointer = null;
    var count: usize = 0;
    while (c.gst_buffer_iterate_meta(copy2, &it) != null) count += 1;
    out(" metas on copy {d}", .{count});
    out(" ctl null {d}", .{@intFromBool(c.gst_buffer_add_net_control_message_meta(buf, null) == null)});
    c.gst_buffer_unref(copy2);
    c.gst_buffer_unref(copy);
    c.gst_buffer_unref(buf);
    c.g_object_unref(cred);
    c.g_object_unref(sa);
    c.g_object_unref(inet);
    out(" tos invalid {d}", .{0});
    const sock = c.g_socket_new(c.G_SOCKET_FAMILY_IPV4, c.G_SOCKET_TYPE_DATAGRAM, c.G_SOCKET_PROTOCOL_UDP, null);
    out(" tos v4 {d}", .{c.gst_net_utils_set_socket_tos(sock, 46)});
    c.g_object_unref(sock);
    const sock6 = c.g_socket_new(c.G_SOCKET_FAMILY_IPV6, c.G_SOCKET_TYPE_DATAGRAM, c.G_SOCKET_PROTOCOL_UDP, null);
    if (sock6 != null) {
        out(" tos v6 {d}", .{c.gst_net_utils_set_socket_tos(sock6, 10)});
        c.g_object_unref(sock6);
    }
}

fn provider() void {
    out("provider", .{});
    const sys = c.gst_system_clock_obtain();
    const bad = c.gst_net_time_provider_new(sys, "not-an-address", 0);
    out(" bad address {d}", .{@intFromBool(bad == null)});
    out(" null clock {d}", .{@intFromBool(c.gst_net_time_provider_new(null, "127.0.0.1", 0) == null)});
    out(" bad port {d}", .{@intFromBool(c.gst_net_time_provider_new(sys, "127.0.0.1", 70000) == null)});
    const p = c.gst_net_time_provider_new(sys, "127.0.0.1", 0);
    var port: c.gint = 0;
    var addr: [*c]u8 = null;
    var active: c.gboolean = 0;
    var dscp: c.gint = 0;
    var clk: ?*anyopaque = null;
    c.g_object_get(p, "port", &port, "address", &addr, "active", &active, "qos-dscp", &dscp, "clock", &clk, @as(?*anyopaque, null));
    out(" port set {d} address {s} active {d} dscp {d} clock {d} floating {d}", .{ @intFromBool(port > 0), str(addr), active, dscp, @intFromBool(clk == @as(?*anyopaque, @ptrCast(sys))), @intFromBool(c.g_object_is_floating(p) != 0) });
    c.g_free(addr);
    if (clk) |k| c.gst_object_unref(k);
    const sock = c.g_socket_new(c.G_SOCKET_FAMILY_IPV4, c.G_SOCKET_TYPE_DATAGRAM, c.G_SOCKET_PROTOCOL_UDP, null);
    const lo = c.g_inet_address_new_from_string("127.0.0.1");
    const dest = c.g_inet_socket_address_new(lo, @intCast(port));
    const req = c.gst_net_time_packet_new(null);
    req.*.local_time = 123456789;
    out(" send {d}", .{c.gst_net_time_packet_send(req, sock, dest, null)});
    c.g_socket_set_timeout(sock, 3);
    var err: [*c]c.GError = null;
    var from: ?*c.GSocketAddress = null;
    const reply = c.gst_net_time_packet_receive(sock, &from, &err);
    if (reply != null) {
        out(" reply local {d} remote valid {d} from port same {d}", .{ reply.*.local_time, @intFromBool(reply.*.remote_time != NONE), @intFromBool(c.g_inet_socket_address_get_port(@ptrCast(from)) == port) });
        c.gst_net_time_packet_free(reply);
        c.g_object_unref(from);
    } else out(" reply error {s}", .{str(err.*.message)});
    c.g_object_set(p, "active", @as(c.gboolean, 0), @as(?*anyopaque, null));
    _ = c.gst_net_time_packet_send(req, sock, dest, null);
    c.g_socket_set_timeout(sock, 1);
    const none = c.gst_net_time_packet_receive(sock, null, &err);
    out(" inactive reply {d} error {d}", .{ @intFromBool(none != null), @intFromBool(err != null) });
    if (err != null) c.g_clear_error(&err);
    c.g_object_set(p, "active", @as(c.gboolean, 1), @as(?*anyopaque, null));
    const short = [_]u8{ 1, 2, 3 };
    _ = c.g_socket_send_to(sock, dest, &short, 3, null, null);
    c.g_socket_set_timeout(sock, 1);
    const after = c.gst_net_time_packet_receive(sock, null, &err);
    out(" short packet reply {d}", .{@intFromBool(after != null)});
    if (err != null) c.g_clear_error(&err);
    out(" receive critical {d}", .{@intFromBool(c.gst_net_time_packet_receive(null, null, null) == null)});
    out(" send critical {d}", .{c.gst_net_time_packet_send(null, sock, dest, null)});
    c.gst_net_time_packet_free(req);
    clients(sys, port);
    c.g_object_unref(dest);
    c.g_object_unref(lo);
    c.g_object_unref(sock);
    c.gst_object_unref(p);
    c.gst_object_unref(sys);
}

fn clients(sys: [*c]c.GstClock, port: c.gint) void {
    _ = sys;
    out("client clock", .{});
    out(" bad args {d} {d} {d} {d}", .{ @intFromBool(c.gst_net_client_clock_new("x", null, 1, 0) == null), @intFromBool(c.gst_net_client_clock_new("x", "127.0.0.1", 0, 0) == null), @intFromBool(c.gst_net_client_clock_new("x", "127.0.0.1", 70000, 0) == null), @intFromBool(c.gst_ntp_clock_new("x", "127.0.0.1", 1, NONE) == null) });
    const a = c.gst_net_client_clock_new("net-a", "127.0.0.1", port, 42 * SEC);
    const b = c.gst_net_client_clock_new("net-b", "127.0.0.1", port, 0);
    var ia: ?*anyopaque = null;
    var ib: ?*anyopaque = null;
    c.g_object_get(a, "internal-clock", &ia, @as(?*anyopaque, null));
    c.g_object_get(b, "internal-clock", &ib, @as(?*anyopaque, null));
    out(" shared internal {d} type {s} name null {d}", .{ @intFromBool(ia != null and ia == ib), str(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(ia))).g_class.*.g_type)), @intFromBool(@as(*c.GstObject, @ptrCast(@alignCast(ia))).name != null) });
    var flags = @as(*c.GstObject, @ptrCast(@alignCast(a))).flags;
    out(" flags {x} internal flags {x}", .{ flags & 0xffff0, @as(*c.GstObject, @ptrCast(@alignCast(ia))).flags & 0xffff0 });
    var is_ntp: c.gboolean = 7;
    c.g_object_get(ia, "is-ntp", &is_ntp, @as(?*anyopaque, null));
    out(" internal is-ntp {d}", .{is_ntp});
    const bus = c.gst_bus_new();
    c.g_object_set(a, "bus", bus, "round-trip-limit", @as(u64, 2 * SEC), "minimum-update-interval", @as(u64, SEC / 10), "qos-dscp", @as(c.gint, 8), @as(?*anyopaque, null));
    var base: u64 = 0;
    var rtl: u64 = 0;
    var mui: u64 = 0;
    var dscp: c.gint = 0;
    var addr: [*c]u8 = null;
    var p: c.gint = 0;
    c.g_object_get(a, "base-time", &base, "round-trip-limit", &rtl, "minimum-update-interval", &mui, "qos-dscp", &dscp, "address", &addr, "port", &p, @as(?*anyopaque, null));
    out(" props base {d} rtl {d} mui {d} dscp {d} addr {s} port same {d}", .{ base, rtl, mui, dscp, str(addr), @intFromBool(p == port) });
    c.g_free(addr);
    const synced = c.gst_clock_wait_for_sync(a, 5 * SEC);
    out(" synced {d} b synced {d}", .{ synced, c.gst_clock_is_synced(b) });
    const msg = c.gst_bus_timed_pop_filtered(bus, 5 * SEC, c.GST_MESSAGE_ELEMENT);
    if (msg != null) {
        const st = c.gst_message_get_structure(msg);
        out(" stats {s} src internal {d}", .{ str(c.gst_structure_get_name(st)), @intFromBool(@as(?*anyopaque, @ptrCast(msg.*.src)) == ia) });
        for (0..@intCast(c.gst_structure_n_fields(st))) |i| {
            const name = c.gst_structure_nth_field_name(st, @intCast(i));
            out("  field {s} {s}", .{ str(name), str(c.g_type_name(c.gst_structure_get_field_type(st, name))) });
        }
        c.gst_message_unref(msg);
    } else out(" no stats", .{});
    const t = c.gst_clock_get_time(a);
    out(" time valid {d}", .{@intFromBool(t != NONE and t > 0)});
    if (ia) |x| c.gst_object_unref(x);
    if (ib) |x| c.gst_object_unref(x);
    c.g_object_set(a, "bus", @as(?*anyopaque, null), @as(?*anyopaque, null));
    c.gst_object_unref(bus);
    c.gst_object_unref(b);
    c.gst_object_unref(a);
    const n = c.gst_ntp_clock_new("ntp", "127.0.0.1", 9, 7 * SEC);
    var in_: ?*anyopaque = null;
    c.g_object_get(n, "internal-clock", &in_, @as(?*anyopaque, null));
    c.g_object_get(in_, "is-ntp", &is_ntp, @as(?*anyopaque, null));
    flags = @as(*c.GstObject, @ptrCast(@alignCast(n))).flags;
    out(" ntp type {s} internal is-ntp {d} synced {d} wait {d}", .{ str(c.g_type_name(@as(*c.GTypeInstance, @ptrCast(@alignCast(n))).g_class.*.g_type)), is_ntp, c.gst_clock_is_synced(n), c.gst_clock_wait_for_sync(n, SEC / 5) });
    if (in_) |x| c.gst_object_unref(x);
    const tn = c.gst_clock_get_time(n);
    out(" ntp time near base {d}", .{@intFromBool(tn >= 7 * SEC and tn < 9 * SEC)});
    c.gst_object_unref(n);
    const unres = c.gst_net_client_clock_new("unres", "no-such-host.invalid", 5637, 0);
    out(" unresolvable internal null {d} synced {d}", .{ @intFromBool(blk: {
        var x: ?*anyopaque = null;
        c.g_object_get(unres, "internal-clock", &x, @as(?*anyopaque, null));
        defer if (x) |y| c.gst_object_unref(y);
        break :blk x == null;
    }), c.gst_clock_is_synced(unres) });
    c.gst_object_unref(unres);
    c.gst_net_client_clock_deinit();
}

var stats_count: usize = 0;

fn onStats(domain: u8, st: ?*const c.GstStructure, data: c.gpointer) callconv(.c) c.gboolean {
    const tag: [*c]const u8 = @ptrCast(data);
    const s = c.gst_structure_to_string(st);
    var text: []const u8 = std.mem.span(s);
    if (std.mem.indexOf(u8, text, "clock=(GstClock)")) |i| text = text[0..i];
    out("  stats[{s}] {d} {s}", .{ str(tag), domain, text });
    c.g_free(s);
    stats_count += 1;
    return @intFromBool(!(tag[0] == 'o' and stats_count > 3));
}

fn ptp(helper: [*c]const u8) void {
    out("ptp", .{});
    out(" supported {d} initialized {d}", .{ c.gst_ptp_is_supported(), c.gst_ptp_is_initialized() });
    const id1 = c.gst_ptp_statistics_callback_add(onStats, @constCast("all"), null);
    const id2 = c.gst_ptp_statistics_callback_add(onStats, @constCast("once"), null);
    out(" ids {d}", .{id2 - id1});
    _ = c.g_setenv("GST_PTP_HELPER_1_0", helper, 1);
    const cfg = c.gst_structure_new("config/ptp", "clock-id", c.G_TYPE_UINT64, @as(u64, 0x1234), "ttl", c.G_TYPE_UINT, @as(c.guint, 3), @as(?*anyopaque, null));
    out(" init {d} initialized {d}", .{ c.gst_ptp_init_full(cfg), c.gst_ptp_is_initialized() });
    c.gst_structure_free(cfg);
    out(" init again {d}", .{c.gst_ptp_init(NONE, null)});
    const k = c.gst_ptp_clock_new("ptp0", 0);
    const k1 = c.gst_ptp_clock_new("ptp1", 1);
    out(" clock {d} synced {d} bad domain {d}", .{ @intFromBool(k != null), c.gst_clock_is_synced(k), @intFromBool(c.gst_ptp_clock_new("x", 300) == null) });
    const synced = c.gst_clock_wait_for_sync(k, 3 * SEC);
    var mc: u64 = 0;
    var gm: u64 = 0;
    var dom: c.guint = 9;
    var internal: ?*anyopaque = null;
    c.g_object_get(k, "master-clock-id", &mc, "grandmaster-clock-id", &gm, "domain", &dom, "internal-clock", &internal, @as(?*anyopaque, null));
    out(" synced {d} master {x} gm {x} domain {d} internal {s}", .{ synced, mc, gm, dom, if (internal) |x| str(@as(*c.GstObject, @ptrCast(@alignCast(x))).name) else "(none)" });
    if (internal) |x| c.gst_object_unref(x);
    c.g_object_get(k1, "master-clock-id", &mc, "internal-clock", &internal, @as(?*anyopaque, null));
    out(" domain1 master {x} internal {d} synced {d}", .{ mc, @intFromBool(internal == null), c.gst_clock_is_synced(k1) });
    c.g_usleep(500000);
    c.gst_ptp_statistics_callback_remove(id1);
    c.gst_ptp_statistics_callback_remove(id1);
    c.gst_object_unref(k);
    c.gst_object_unref(k1);
    c.gst_ptp_deinit();
    out(" after deinit initialized {d} supported {d}", .{ c.gst_ptp_is_initialized(), c.gst_ptp_is_supported() });
    _ = c.g_setenv("GST_PTP_HELPER_1_0", "/nonexistent/gst-ptp-helper", 1);
    out(" init missing helper {d} supported {d}", .{ c.gst_ptp_init(NONE, null), c.gst_ptp_is_supported() });
    out(" clock after failure {d}", .{@intFromBool(c.gst_ptp_clock_new("y", 0) == null)});
    out(" init after failure {d}", .{c.gst_ptp_init(NONE, null)});
}

pub fn main() void {
    c.gst_init(null, null);
    _ = c.g_log_set_handler("GStreamer-Net", c.G_LOG_LEVEL_MASK | c.G_LOG_FLAG_FATAL | c.G_LOG_FLAG_RECURSION, logger, null);
    for ([_]c.GType{ c.gst_net_time_provider_get_type(), c.gst_net_client_clock_get_type(), c.gst_ntp_clock_get_type(), c.gst_ptp_clock_get_type(), c.gst_net_time_packet_get_type(), c.gst_net_address_meta_api_get_type(), c.gst_net_control_message_meta_api_get_type() }) |t| describe(t);
    packets();
    metas();
    provider();
    var self: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &self, self.len - 32);
    const dir = std.fs.path.dirname(self[0..@intCast(n)]).?;
    var path: [4096]u8 = undefined;
    const h = std.fmt.bufPrintSentinel(&path, "{s}/diff-ptphelper", .{dir}, 0) catch unreachable;
    ptp(h.ptr);
    out("done", .{});
}
