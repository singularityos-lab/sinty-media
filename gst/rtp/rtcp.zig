const std = @import("std");
const c = @import("../c.zig").c;
const buf = @import("buffer.zig");
const that = buf.that;

comptime {
    @import("../abi.zig").check(@This());
}

const Pkt = c.GstRTCPPacket;
const Rtcp = c.GstRTCPBuffer;
const R = c.GST_MAP_READ;
const W = c.GST_MAP_WRITE;
const SRC = "../gst-libs/gst/rtp/gstrtcpbuffer.c";

const Kind = struct { e: []const u8, t: []const c_uint };

const ANY = Kind{ .e = "", .t = &.{} };
const SR = Kind{ .e = "packet->type == GST_RTCP_TYPE_SR", .t = &.{c.GST_RTCP_TYPE_SR} };
const RR = Kind{ .e = "packet->type == GST_RTCP_TYPE_RR", .t = &.{c.GST_RTCP_TYPE_RR} };
const RRSR = Kind{ .e = "packet->type == GST_RTCP_TYPE_RR || packet->type == GST_RTCP_TYPE_SR", .t = &.{ c.GST_RTCP_TYPE_RR, c.GST_RTCP_TYPE_SR } };
const SDES = Kind{ .e = "packet->type == GST_RTCP_TYPE_SDES", .t = &.{c.GST_RTCP_TYPE_SDES} };
const BYE = Kind{ .e = "packet->type == GST_RTCP_TYPE_BYE", .t = &.{c.GST_RTCP_TYPE_BYE} };
const APP = Kind{ .e = "packet->type == GST_RTCP_TYPE_APP", .t = &.{c.GST_RTCP_TYPE_APP} };
const XR = Kind{ .e = "packet->type == GST_RTCP_TYPE_XR", .t = &.{c.GST_RTCP_TYPE_XR} };
const FB = Kind{ .e = "packet->type == GST_RTCP_TYPE_RTPFB || packet->type == GST_RTCP_TYPE_PSFB", .t = &.{ c.GST_RTCP_TYPE_RTPFB, c.GST_RTCP_TYPE_PSFB } };
const FBP = Kind{ .e = "(packet->type == GST_RTCP_TYPE_RTPFB || packet->type == GST_RTCP_TYPE_PSFB)", .t = FB.t };

fn guard(p: [*c]Pkt, comptime f: []const u8, comptime k: Kind, comptime mode: c_uint) bool {
    if (!that(p != null, f, "packet != NULL")) return false;
    if (k.t.len != 0) {
        var hit = false;
        inline for (k.t) |t| hit = hit or p[0].type == t;
        if (!that(hit, f, k.e)) return false;
    }
    if (mode == 0) return true;
    if (!that(p[0].rtcp != null, f, "packet->rtcp != NULL")) return false;
    const e = if (mode == W) "packet->rtcp->map.flags & GST_MAP_WRITE" else "packet->rtcp->map.flags & GST_MAP_READ";
    return that(p[0].rtcp[0].map.flags & mode != 0, f, e);
}

fn reached(comptime f: []const u8, line: c_int) void {
    c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_CRITICAL, "file %s: line %d (%s): should not be reached", SRC, line, @as([*c]const u8, f ++ ""));
}

fn rd16(p: [*c]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .big);
}

fn rd32(p: [*c]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

fn rd64(p: [*c]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .big);
}

fn wr16(p: [*c]u8, v: u16) void {
    std.mem.writeInt(u16, p[0..2], v, .big);
}

fn wr32(p: [*c]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .big);
}

fn wr64(p: [*c]u8, v: u64) void {
    std.mem.writeInt(u64, p[0..8], v, .big);
}

fn base(p: [*c]Pkt) [*c]u8 {
    return p[0].rtcp[0].map.data + p[0].offset;
}

fn block(p: [*c]Pkt) [*c]u8 {
    return base(p) + p[0].item_offset;
}

fn setLength(p: [*c]Pkt) void {
    wr16(base(p) + 2, p[0].length);
}

pub export fn gst_rtcp_buffer_new_take_data(data: c.gpointer, len: c.guint) [*c]c.GstBuffer {
    const f = "gst_rtcp_buffer_new_take_data";
    if (!that(data != null, f, "data != NULL")) return null;
    if (!that(len > 0, f, "len > 0")) return null;
    return c.gst_buffer_new_wrapped(data, len);
}

pub export fn gst_rtcp_buffer_new_copy_data(data: c.gconstpointer, len: c.guint) [*c]c.GstBuffer {
    return gst_rtcp_buffer_new_take_data(c.g_memdup2(data, len), len);
}

fn validate(data: [*c]u8, len: c.guint, mask: u16) c.gboolean {
    if (!that(data != null, "gst_rtcp_buffer_validate_data_internal", "data != NULL")) return 0;
    if (len < 4) return 0;
    if (rd16(data) & mask != (c.GST_RTCP_VERSION << 14) | c.GST_RTCP_TYPE_SR) return 0;
    var padded = data[0] & 0x20 != 0;
    var d = data;
    var left: c.guint = len;
    while (true) {
        const n = (@as(c.guint, rd16(d + 2)) + 1) << 2;
        if (left < n) return 0;
        d += n;
        left -= n;
        if (left < 4 or padded) break;
        if (d[0] & 0xc0 != c.GST_RTCP_VERSION << 6) return 0;
        if (d[0] & 0x20 != 0) {
            padded = true;
            const pad = d[left - 1];
            if (pad == 0 or pad & 3 != 0) return 0;
        }
    }
    return @intFromBool(left == 0);
}

pub export fn gst_rtcp_buffer_validate_data_reduced(data: [*c]u8, len: c.guint) c.gboolean {
    return validate(data, len, c.GST_RTCP_REDUCED_SIZE_VALID_MASK);
}

pub export fn gst_rtcp_buffer_validate_data(data: [*c]u8, len: c.guint) c.gboolean {
    return validate(data, len, c.GST_RTCP_VALID_MASK);
}

fn validateBuffer(b: [*c]c.GstBuffer, comptime f: []const u8, mask: u16) c.gboolean {
    if (!that(buf.isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    var map: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(b, &map, c.GST_MAP_READ);
    defer c.gst_buffer_unmap(b, &map);
    return validate(map.data, @truncate(map.size), mask);
}

pub export fn gst_rtcp_buffer_validate_reduced(b: [*c]c.GstBuffer) c.gboolean {
    return validateBuffer(b, "gst_rtcp_buffer_validate_reduced", c.GST_RTCP_REDUCED_SIZE_VALID_MASK);
}

pub export fn gst_rtcp_buffer_validate(b: [*c]c.GstBuffer) c.gboolean {
    return validateBuffer(b, "gst_rtcp_buffer_validate", c.GST_RTCP_VALID_MASK);
}

pub export fn gst_rtcp_buffer_new(mtu: c.guint) [*c]c.GstBuffer {
    if (!that(mtu > 0, "gst_rtcp_buffer_new", "mtu > 0")) return null;
    const data = c.g_malloc0(mtu);
    return c.gst_buffer_new_wrapped_full(0, data, mtu, 0, 0, data, c.g_free);
}

pub export fn gst_rtcp_buffer_map(b: [*c]c.GstBuffer, flags: c.GstMapFlags, rtcp: [*c]Rtcp) c.gboolean {
    const f = "gst_rtcp_buffer_map";
    if (!that(rtcp != null, f, "rtcp != NULL")) return 0;
    if (!that(rtcp[0].buffer == null, f, "rtcp->buffer == NULL")) return 0;
    if (!that(buf.isBuffer(b), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!that(flags & R != 0, f, "flags & GST_MAP_READ")) return 0;
    rtcp[0].buffer = b;
    _ = c.gst_buffer_map(b, &rtcp[0].map, flags);
    return 1;
}

pub export fn gst_rtcp_buffer_unmap(rtcp: [*c]Rtcp) c.gboolean {
    const f = "gst_rtcp_buffer_unmap";
    if (!that(rtcp != null, f, "rtcp != NULL")) return 0;
    if (!that(buf.isBuffer(rtcp[0].buffer), f, "GST_IS_BUFFER (rtcp->buffer)")) return 0;
    if (rtcp[0].map.flags & W != 0) c.gst_buffer_resize(rtcp[0].buffer, 0, @intCast(rtcp[0].map.size));
    c.gst_buffer_unmap(rtcp[0].buffer, &rtcp[0].map);
    rtcp[0].buffer = null;
    return 1;
}

fn bufferReady(rtcp: [*c]Rtcp, comptime f: []const u8) bool {
    if (!that(rtcp != null, f, "rtcp != NULL")) return false;
    return that(buf.isBuffer(rtcp[0].buffer), f, "GST_IS_BUFFER (rtcp->buffer)");
}

pub export fn gst_rtcp_buffer_get_packet_count(rtcp: [*c]Rtcp) c.guint {
    const f = "gst_rtcp_buffer_get_packet_count";
    if (!bufferReady(rtcp, f)) return 0;
    if (!that(rtcp[0].map.flags & R != 0, f, "rtcp->map.flags & GST_MAP_READ")) return 0;
    var p: Pkt = undefined;
    var n: c.guint = 0;
    if (gst_rtcp_buffer_get_first_packet(rtcp, &p) != 0) {
        n += 1;
        while (gst_rtcp_packet_move_to_next(&p) != 0) n += 1;
    }
    return n;
}

fn minLen(t: c.GstRTCPType) ?c.guint {
    return switch (t) {
        c.GST_RTCP_TYPE_SR => 28,
        c.GST_RTCP_TYPE_RR, c.GST_RTCP_TYPE_XR => 8,
        c.GST_RTCP_TYPE_SDES, c.GST_RTCP_TYPE_BYE => 4,
        c.GST_RTCP_TYPE_APP, c.GST_RTCP_TYPE_RTPFB, c.GST_RTCP_TYPE_PSFB => 12,
        else => null,
    };
}

fn header(p: [*c]Pkt) bool {
    const d = p[0].rtcp[0].map.data;
    const size = p[0].rtcp[0].map.size;
    const o = p[0].offset;
    if (@as(usize, o) + 4 > size) return false;
    if (d[o] & 0xc0 != c.GST_RTCP_VERSION << 6) return false;
    p[0].padding = @intFromBool(d[o] & 0x20 != 0);
    p[0].count = d[o] & 0x1f;
    p[0].type = d[o + 1];
    p[0].length = rd16(d + o + 2);
    p[0].item_offset = 4;
    p[0].item_count = 0;
    p[0].entry_offset = 4;
    if (@as(usize, o) + 4 + @as(usize, p[0].length) * 4 > size) return false;
    const min = minLen(p[0].type) orelse return false;
    return p[0].length >= (min - 4) >> 2;
}

pub export fn gst_rtcp_buffer_get_first_packet(rtcp: [*c]Rtcp, p: [*c]Pkt) c.gboolean {
    const f = "gst_rtcp_buffer_get_first_packet";
    if (!bufferReady(rtcp, f)) return 0;
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(rtcp[0].map.flags & R != 0, f, "rtcp->map.flags & GST_MAP_READ")) return 0;
    p[0].rtcp = rtcp;
    p[0].offset = 0;
    p[0].type = c.GST_RTCP_TYPE_INVALID;
    return @intFromBool(header(p));
}

pub export fn gst_rtcp_packet_move_to_next(p: [*c]Pkt) c.gboolean {
    const f = "gst_rtcp_packet_move_to_next";
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(p[0].type != c.GST_RTCP_TYPE_INVALID, f, "packet->type != GST_RTCP_TYPE_INVALID")) return 0;
    if (!that(p[0].rtcp != null, f, "packet->rtcp != NULL")) return 0;
    if (!that(p[0].rtcp[0].map.flags & R != 0, f, "packet->rtcp->map.flags & GST_MAP_READ")) return 0;
    if (p[0].padding == 0) {
        p[0].offset += (@as(c.guint, p[0].length) << 2) + 4;
        if (header(p)) return 1;
    }
    p[0].type = c.GST_RTCP_TYPE_INVALID;
    return 0;
}

pub export fn gst_rtcp_buffer_add_packet(rtcp: [*c]Rtcp, t: c.GstRTCPType, p: [*c]Pkt) c.gboolean {
    const f = "gst_rtcp_buffer_add_packet";
    if (!bufferReady(rtcp, f)) return 0;
    if (!that(t != c.GST_RTCP_TYPE_INVALID, f, "type != GST_RTCP_TYPE_INVALID")) return 0;
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(rtcp[0].map.flags & W != 0, f, "rtcp->map.flags & GST_MAP_WRITE")) return 0;
    if (gst_rtcp_buffer_get_first_packet(rtcp, p) != 0) {
        while (gst_rtcp_packet_move_to_next(p) != 0) {}
        if (p[0].padding != 0) return 0;
    }
    const len = minLen(t) orelse {
        c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_WARNING, "unknown type %d", t);
        return 0;
    };
    if (@as(usize, p[0].offset) + len >= rtcp[0].map.maxsize) return 0;
    rtcp[0].map.size += len;
    const d = rtcp[0].map.data + p[0].offset;
    d[0] = c.GST_RTCP_VERSION << 6;
    d[1] = @truncate(t);
    wr16(d + 2, @intCast((len - 4) >> 2));
    return @intFromBool(header(p));
}

pub export fn gst_rtcp_packet_remove(p: [*c]Pkt) c.gboolean {
    const f = "gst_rtcp_packet_remove";
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(p[0].type != c.GST_RTCP_TYPE_INVALID, f, "packet->type != GST_RTCP_TYPE_INVALID")) return 0;
    if (!that(p[0].rtcp != null, f, "packet->rtcp != NULL")) return 0;
    if (!that(p[0].rtcp[0].map.flags & W != 0, f, "packet->rtcp->map.flags & GST_MAP_WRITE")) return 0;
    const m = &p[0].rtcp[0].map;
    const next = p[0].offset + (@as(c.guint, p[0].length) << 2) + 4;
    const d: [*]u8 = @ptrCast(m.data);
    const rest = m.size - next;
    std.mem.copyForwards(u8, d[p[0].offset .. p[0].offset + rest], d[next .. next + rest]);
    m.size -= next - p[0].offset;
    if (header(p)) return 1;
    p[0].type = c.GST_RTCP_TYPE_INVALID;
    return 0;
}

pub export fn gst_rtcp_packet_get_padding(p: [*c]Pkt) c.gboolean {
    const f = "gst_rtcp_packet_get_padding";
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(p[0].type != c.GST_RTCP_TYPE_INVALID, f, "packet->type != GST_RTCP_TYPE_INVALID")) return 0;
    return p[0].padding;
}

pub export fn gst_rtcp_packet_get_type(p: [*c]Pkt) c.GstRTCPType {
    if (!that(p != null, "gst_rtcp_packet_get_type", "packet != NULL")) return c.GST_RTCP_TYPE_INVALID;
    return p[0].type;
}

pub export fn gst_rtcp_packet_get_count(p: [*c]Pkt) u8 {
    const f = "gst_rtcp_packet_get_count";
    if (!that(p != null, f, "packet != NULL")) return 0xff;
    if (!that(p[0].type != c.GST_RTCP_TYPE_INVALID, f, "packet->type != GST_RTCP_TYPE_INVALID")) return 0xff;
    return p[0].count;
}

pub export fn gst_rtcp_packet_get_length(p: [*c]Pkt) c.guint16 {
    const f = "gst_rtcp_packet_get_length";
    if (!that(p != null, f, "packet != NULL")) return 0;
    if (!that(p[0].type != c.GST_RTCP_TYPE_INVALID, f, "packet->type != GST_RTCP_TYPE_INVALID")) return 0;
    return p[0].length;
}

pub export fn gst_rtcp_packet_sr_get_sender_info(p: [*c]Pkt, ssrc: [*c]c.guint32, ntp: [*c]c.guint64, rtp: [*c]c.guint32, packets: [*c]c.guint32, octets: [*c]c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_sr_get_sender_info", SR, R)) return;
    const d = base(p) + 4;
    if (ssrc != null) ssrc.* = rd32(d);
    if (ntp != null) ntp.* = rd64(d + 4);
    if (rtp != null) rtp.* = rd32(d + 12);
    if (packets != null) packets.* = rd32(d + 16);
    if (octets != null) octets.* = rd32(d + 20);
}

pub export fn gst_rtcp_packet_sr_set_sender_info(p: [*c]Pkt, ssrc: c.guint32, ntp: c.guint64, rtp: c.guint32, packets: c.guint32, octets: c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_sr_set_sender_info", SR, W)) return;
    const d = base(p) + 4;
    wr32(d, ssrc);
    wr64(d + 4, ntp);
    wr32(d + 12, rtp);
    wr32(d + 16, packets);
    wr32(d + 20, octets);
}

pub export fn gst_rtcp_packet_rr_get_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_rr_get_ssrc", RR, R)) return 0;
    return rd32(base(p) + 4);
}

pub export fn gst_rtcp_packet_rr_set_ssrc(p: [*c]Pkt, ssrc: c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_rr_set_ssrc", RR, W)) return;
    wr32(base(p) + 4, ssrc);
}

pub export fn gst_rtcp_packet_get_rb_count(p: [*c]Pkt) c.guint {
    if (!guard(p, "gst_rtcp_packet_get_rb_count", RRSR, R)) return 0;
    return p[0].count;
}

pub export fn gst_rtcp_packet_get_rb(p: [*c]Pkt, nth: c.guint, ssrc: [*c]c.guint32, fraction: [*c]u8, lost: [*c]c.gint32, highest: [*c]c.guint32, jitter: [*c]c.guint32, lsr: [*c]c.guint32, dlsr: [*c]c.guint32) void {
    const f = "gst_rtcp_packet_get_rb";
    if (!guard(p, f, RRSR, R)) return;
    if (!that(nth < p[0].count, f, "nth < packet->count")) return;
    var words: c.guint = if (p[0].type == c.GST_RTCP_TYPE_RR) 2 else 7;
    words += nth * 6;
    if (words > p[0].length) return;
    const o = (words << 2) + p[0].offset;
    if (@as(usize, o) + 24 > p[0].rtcp[0].map.size) return;
    const d = p[0].rtcp[0].map.data + o;
    if (ssrc != null) ssrc.* = rd32(d);
    const v = rd32(d + 4);
    if (fraction != null) fraction.* = @truncate(v >> 24);
    if (lost != null) lost.* = @as(i32, @bitCast(v << 8)) >> 8;
    if (highest != null) highest.* = rd32(d + 8);
    if (jitter != null) jitter.* = rd32(d + 12);
    if (lsr != null) lsr.* = rd32(d + 16);
    if (dlsr != null) dlsr.* = rd32(d + 20);
}

pub export fn gst_rtcp_packet_add_rb(p: [*c]Pkt, ssrc: c.guint32, fraction: u8, lost: c.gint32, highest: c.guint32, jitter: c.guint32, lsr: c.guint32, dlsr: c.guint32) c.gboolean {
    const f = "gst_rtcp_packet_add_rb";
    if (!guard(p, f, RRSR, W)) return 0;
    if (!that(gst_rtcp_packet_get_profile_specific_ext_length(p) == 0, f, "gst_rtcp_packet_get_profile_specific_ext_length (packet) == 0")) return 0;
    if (p[0].count >= c.GST_RTCP_MAX_RB_COUNT) return 0;
    const maxsize: c.guint = @truncate(p[0].rtcp[0].map.maxsize);
    const o = p[0].offset + 4 + @as(c.guint, if (p[0].type == c.GST_RTCP_TYPE_RR) 4 else 24) + @as(c.guint, p[0].count) * 24;
    if (o + 24 >= maxsize) return 0;
    const all = p[0].rtcp[0].map.data;
    p[0].count += 1;
    all[p[0].offset] +%= 1;
    p[0].length += 6;
    setLength(p);
    p[0].rtcp[0].map.size += 24;
    const d = all + o;
    wr32(d, ssrc);
    wr32(d + 4, (@as(u32, fraction) << 24) | (@as(u32, @bitCast(lost)) & 0xffffff));
    wr32(d + 8, highest);
    wr32(d + 12, jitter);
    wr32(d + 16, lsr);
    wr32(d + 20, dlsr);
    return 1;
}

pub export fn gst_rtcp_packet_set_rb(p: [*c]Pkt, nth: c.guint, ssrc: c.guint32, fraction: u8, lost: c.gint32, highest: c.guint32, jitter: c.guint32, lsr: c.guint32, dlsr: c.guint32) void {
    _ = .{ nth, ssrc, fraction, lost, highest, jitter, lsr, dlsr };
    if (!guard(p, "gst_rtcp_packet_set_rb", RRSR, W)) return;
    c.g_log(buf.DOMAIN, c.G_LOG_LEVEL_WARNING, "not implemented");
}

pub export fn gst_rtcp_packet_add_profile_specific_ext(p: [*c]Pkt, data: [*c]const u8, len: c.guint) c.gboolean {
    const f = "gst_rtcp_packet_add_profile_specific_ext";
    if (!guard(p, f, RRSR, W)) return 0;
    if (!that(len & 3 == 0, f, "(len & 0x03) == 0")) return 0;
    const maxsize: c.guint = @truncate(p[0].rtcp[0].map.maxsize);
    const o = p[0].offset + (@as(c.guint, p[0].length) << 2) + 4;
    if (o + len > maxsize) return 0;
    @memcpy(p[0].rtcp[0].map.data[o .. o + len], data[0..len]);
    p[0].length +%= @truncate(len >> 2);
    setLength(p);
    p[0].rtcp[0].map.size += len;
    return 1;
}

pub export fn gst_rtcp_packet_get_profile_specific_ext_length(p: [*c]Pkt) c.guint16 {
    if (!guard(p, "gst_rtcp_packet_get_profile_specific_ext_length", RRSR, R)) return 0;
    var o: c.guint = if (p[0].type == c.GST_RTCP_TYPE_SR) 7 else 2;
    o += @as(c.guint, p[0].count) * 6;
    const end = @as(c.guint, p[0].length) + 1;
    return if (o <= end) @truncate(end - o) else 0;
}

fn pse(p: [*c]Pkt, comptime f: []const u8, data: [*c][*c]u8, len: [*c]c.guint, dup: bool) c.gboolean {
    if (!guard(p, f, RRSR, R)) return 0;
    const n = gst_rtcp_packet_get_profile_specific_ext_length(p);
    if (n == 0) return 0;
    const bytes = @as(c.guint, n) * 4;
    if (len != null) len.* = bytes;
    if (data != null) {
        const at = base(p) + (@as(c.guint, p[0].length) + 1 - n) * 4;
        data.* = if (dup) @ptrCast(c.g_memdup2(at, bytes)) else at;
    }
    return 1;
}

pub export fn gst_rtcp_packet_get_profile_specific_ext(p: [*c]Pkt, data: [*c][*c]u8, len: [*c]c.guint) c.gboolean {
    return pse(p, "gst_rtcp_packet_get_profile_specific_ext", data, len, false);
}

pub export fn gst_rtcp_packet_copy_profile_specific_ext(p: [*c]Pkt, data: [*c][*c]u8, len: [*c]c.guint) c.gboolean {
    return pse(p, "gst_rtcp_packet_copy_profile_specific_ext", data, len, true);
}

pub export fn gst_rtcp_packet_sdes_get_item_count(p: [*c]Pkt) c.guint {
    if (!guard(p, "gst_rtcp_packet_sdes_get_item_count", SDES, 0)) return 0;
    return p[0].count;
}

pub export fn gst_rtcp_packet_sdes_first_item(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_first_item", SDES, 0)) return 0;
    p[0].item_offset = 4;
    p[0].item_count = 0;
    p[0].entry_offset = 4;
    return @intFromBool(p[0].count != 0);
}

pub export fn gst_rtcp_packet_sdes_next_item(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_next_item", SDES, R)) return 0;
    if (p[0].item_count == p[0].count) return 0;
    const d = base(p);
    const end = @as(c.guint, p[0].length) << 2;
    var o = p[0].item_offset + 4;
    while (o < end) {
        if (d[o] == 0) {
            o = (o + 4) & ~@as(c.guint, 3);
            break;
        }
        o += @as(c.guint, d[o + 1]) + 2;
    }
    if (o >= end) return 0;
    p[0].item_offset = o;
    p[0].item_count += 1;
    p[0].entry_offset = 4;
    return 1;
}

pub export fn gst_rtcp_packet_sdes_get_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_sdes_get_ssrc", SDES, R)) return 0;
    return rd32(block(p));
}

pub export fn gst_rtcp_packet_sdes_first_entry(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_first_entry", SDES, R)) return 0;
    const o = p[0].item_offset + 4;
    p[0].entry_offset = 4;
    if (o >= @as(c.guint, p[0].length) << 2) return 0;
    return @intFromBool(base(p)[o] != 0);
}

pub export fn gst_rtcp_packet_sdes_next_entry(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_next_entry", SDES, R)) return 0;
    const d = base(p);
    const end = @as(c.guint, p[0].length) << 2;
    var o = p[0].item_offset + p[0].entry_offset;
    if (o + 1 >= end) return 0;
    const step = @as(c.guint, d[o + 1]) + 2;
    o += step;
    if (o >= end) return 0;
    p[0].entry_offset += step;
    return @intFromBool(d[o] != 0);
}

pub export fn gst_rtcp_packet_sdes_get_entry(p: [*c]Pkt, t: [*c]c.GstRTCPSDESType, len: [*c]u8, data: [*c][*c]u8) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_get_entry", SDES, R)) return 0;
    const d = base(p);
    const o = p[0].item_offset + p[0].entry_offset;
    if (o + 1 >= @as(c.guint, p[0].length) << 2) return 0;
    if (d[o] == 0) return 0;
    if (t != null) t.* = d[o];
    if (len != null) len.* = d[o + 1];
    if (data != null) data.* = d + o + 2;
    return 1;
}

pub export fn gst_rtcp_packet_sdes_copy_entry(p: [*c]Pkt, t: [*c]c.GstRTCPSDESType, len: [*c]u8, data: [*c][*c]u8) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_copy_entry", SDES, R)) return 0;
    var n: u8 = 0;
    var at: [*c]u8 = null;
    if (gst_rtcp_packet_sdes_get_entry(p, t, &n, &at) == 0) return 0;
    if (len != null) len.* = n;
    if (data != null) data.* = @ptrCast(c.g_strndup(@ptrCast(at), n));
    return 1;
}

pub export fn gst_rtcp_packet_sdes_add_item(p: [*c]Pkt, ssrc: c.guint32) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_add_item", SDES, W)) return 0;
    if (p[0].count >= c.GST_RTCP_MAX_SDES_ITEM_COUNT) return 0;
    p[0].count += 1;
    _ = gst_rtcp_packet_sdes_next_item(p);
    const d = base(p);
    const o = p[0].item_offset;
    if (@as(usize, o) + 8 >= p[0].rtcp[0].map.maxsize) {
        p[0].count -= 1;
        return 0;
    }
    wr32(d + o, ssrc);
    wr32(d + o + 4, 0);
    d[0] = (d[0] & 0xe0) | p[0].count;
    p[0].length += 2;
    setLength(p);
    p[0].rtcp[0].map.size += 8;
    return 1;
}

pub export fn gst_rtcp_packet_sdes_add_entry(p: [*c]Pkt, t: c.GstRTCPSDESType, len: u8, data: [*c]const u8) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_sdes_add_entry", SDES, W)) return 0;
    const d = base(p);
    const o = p[0].item_offset + p[0].entry_offset;
    const padded = (o + 2 + len + 1 + 3) & ~@as(c.guint, 3);
    if (@as(usize, p[0].offset) + padded >= p[0].rtcp[0].map.maxsize) return 0;
    p[0].rtcp[0].map.size = p[0].offset + padded;
    d[o] = @truncate(@as(c_uint, @bitCast(t)));
    d[o + 1] = len;
    @memcpy(d[o + 2 .. o + 2 + len], data[0..len]);
    d[o + 2 + len] = 0;
    p[0].length = @truncate((padded - 4) >> 2);
    setLength(p);
    p[0].entry_offset += 2 + @as(c.guint, len);
    return 1;
}

pub export fn gst_rtcp_packet_bye_get_ssrc_count(p: [*c]Pkt) c.guint {
    if (!guard(p, "gst_rtcp_packet_bye_get_ssrc_count", BYE, 0)) return std.math.maxInt(c.guint);
    return p[0].count;
}

pub export fn gst_rtcp_packet_bye_get_nth_ssrc(p: [*c]Pkt, nth: c.guint) c.guint32 {
    const f = "gst_rtcp_packet_bye_get_nth_ssrc";
    if (!guard(p, f, BYE, R)) return 0;
    if (!that(nth < p[0].count, f, "nth < packet->count")) return 0;
    const w = 1 + nth;
    if (w > p[0].length) return 0;
    const o = (w << 2) + p[0].offset;
    if (@as(usize, o) + 4 > p[0].rtcp[0].map.size) return 0;
    return rd32(p[0].rtcp[0].map.data + o);
}

pub export fn gst_rtcp_packet_bye_add_ssrc(p: [*c]Pkt, ssrc: c.guint32) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_bye_add_ssrc", BYE, W)) return 0;
    if (p[0].count >= c.GST_RTCP_MAX_BYE_SSRC_COUNT) return 0;
    const all = p[0].rtcp[0].map.data;
    const o = p[0].offset + 4 + @as(c.guint, p[0].count) * 4;
    if (@as(usize, o) + 4 >= p[0].rtcp[0].map.maxsize) return 0;
    p[0].count += 1;
    all[p[0].offset] +%= 1;
    p[0].length += 1;
    setLength(p);
    p[0].rtcp[0].map.size += 4;
    wr32(all + o, ssrc);
    return 1;
}

pub export fn gst_rtcp_packet_bye_add_ssrcs(p: [*c]Pkt, ssrc: [*c]c.guint32, len: c.guint) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_bye_add_ssrcs", BYE, W)) return 0;
    var i: c.guint = 0;
    while (i < len) : (i += 1) {
        if (gst_rtcp_packet_bye_add_ssrc(p, ssrc[i]) == 0) return 0;
    }
    return 1;
}

fn reasonAt(p: [*c]Pkt) c.guint {
    const w = 1 + @as(c.guint, p[0].count);
    if (w > p[0].length) return 0;
    const o = (w << 2) + p[0].offset;
    if (@as(usize, o) + 1 > p[0].rtcp[0].map.size) return 0;
    return o;
}

pub export fn gst_rtcp_packet_bye_get_reason_len(p: [*c]Pkt) u8 {
    if (!guard(p, "gst_rtcp_packet_bye_get_reason_len", BYE, R)) return 0;
    const o = reasonAt(p);
    return if (o == 0) 0 else p[0].rtcp[0].map.data[o];
}

pub export fn gst_rtcp_packet_bye_get_reason(p: [*c]Pkt) [*c]u8 {
    if (!guard(p, "gst_rtcp_packet_bye_get_reason", BYE, R)) return null;
    const o = reasonAt(p);
    if (o == 0) return null;
    const d = p[0].rtcp[0].map.data;
    const n = d[o];
    if (n == 0) return null;
    if (@as(usize, o) + 1 + n > p[0].rtcp[0].map.size) return null;
    return c.g_strndup(@ptrCast(d + o + 1), n);
}

pub export fn gst_rtcp_packet_bye_set_reason(p: [*c]Pkt, reason: [*c]const u8) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_bye_set_reason", BYE, W)) return 0;
    if (reason == null) return 1;
    const n: u8 = @truncate(std.mem.len(reason));
    if (n == 0) return 1;
    p[0].length +%= 1;
    const o = reasonAt(p);
    const padded: u8 = @truncate((@as(c.guint, n) + 1 + 3) & ~@as(c.guint, 3));
    if (o == 0 or @as(usize, o) + padded >= p[0].rtcp[0].map.maxsize) {
        p[0].length -%= 1;
        return 0;
    }
    const d = p[0].rtcp[0].map.data;
    d[o] = n;
    @memcpy(d[o + 1 .. o + 1 + n], reason[0..n]);
    p[0].length +%= (padded >> 2) -% 1;
    setLength(p);
    p[0].rtcp[0].map.size += padded;
    return 1;
}

pub export fn gst_rtcp_packet_fb_get_sender_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_fb_get_sender_ssrc", FBP, R)) return 0;
    return rd32(base(p) + 4);
}

pub export fn gst_rtcp_packet_fb_set_sender_ssrc(p: [*c]Pkt, ssrc: c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_fb_set_sender_ssrc", FB, R)) return;
    wr32(base(p) + 4, ssrc);
}

pub export fn gst_rtcp_packet_fb_get_media_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_fb_get_media_ssrc", FBP, R)) return 0;
    return rd32(base(p) + 8);
}

pub export fn gst_rtcp_packet_fb_set_media_ssrc(p: [*c]Pkt, ssrc: c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_fb_set_media_ssrc", FB, W)) return;
    wr32(base(p) + 8, ssrc);
}

pub export fn gst_rtcp_packet_fb_get_type(p: [*c]Pkt) c.GstRTCPFBType {
    if (!guard(p, "gst_rtcp_packet_fb_get_type", FB, 0)) return c.GST_RTCP_FB_TYPE_INVALID;
    return p[0].count;
}

pub export fn gst_rtcp_packet_fb_set_type(p: [*c]Pkt, t: c.GstRTCPFBType) void {
    if (!guard(p, "gst_rtcp_packet_fb_set_type", FB, W)) return;
    const d = base(p);
    d[0] = (d[0] & 0xe0) | @as(u8, @truncate(t));
    p[0].count = @truncate(t);
}

const NTP_EPOCH: u64 = 2208988800 << 32;

pub export fn gst_rtcp_ntp_to_unix(ntp: c.guint64) c.guint64 {
    return c.gst_util_uint64_scale_ceil(ntp -% NTP_EPOCH, c.GST_SECOND, 1 << 32);
}

pub export fn gst_rtcp_unix_to_ntp(unix: c.guint64) c.guint64 {
    return c.gst_util_uint64_scale(unix, 1 << 32, c.GST_SECOND) +% NTP_EPOCH;
}

const sdes_names = [_]struct { t: c.GstRTCPSDESType, n: [:0]const u8 }{
    .{ .t = c.GST_RTCP_SDES_CNAME, .n = "cname" },
    .{ .t = c.GST_RTCP_SDES_NAME, .n = "name" },
    .{ .t = c.GST_RTCP_SDES_EMAIL, .n = "email" },
    .{ .t = c.GST_RTCP_SDES_PHONE, .n = "phone" },
    .{ .t = c.GST_RTCP_SDES_LOC, .n = "location" },
    .{ .t = c.GST_RTCP_SDES_TOOL, .n = "tool" },
    .{ .t = c.GST_RTCP_SDES_NOTE, .n = "note" },
    .{ .t = c.GST_RTCP_SDES_PRIV, .n = "priv" },
    .{ .t = c.GST_RTCP_SDES_H323_CADDR, .n = "h323-caddr" },
    .{ .t = c.GST_RTCP_SDES_APSI, .n = "apsi" },
    .{ .t = c.GST_RTCP_SDES_RGRP, .n = "rgrp" },
    .{ .t = c.GST_RTCP_SDES_REPAIRED_RTP_STREAM_ID, .n = "repaired-rtp-stream-id" },
    .{ .t = c.GST_RTCP_SDES_CCID, .n = "ccid" },
    .{ .t = c.GST_RTCP_SDES_RTP_STREAM_ID, .n = "rtp-stream-id" },
    .{ .t = c.GST_RTCP_SDES_MID, .n = "mid" },
};

pub export fn gst_rtcp_sdes_type_to_name(t: c.GstRTCPSDESType) [*c]const u8 {
    for (sdes_names) |e| if (e.t == t) return e.n.ptr;
    return null;
}

pub export fn gst_rtcp_sdes_name_to_type(name: [*c]const u8) c.GstRTCPSDESType {
    if (name == null or name[0] == 0) return c.GST_RTCP_SDES_INVALID;
    const s = std.mem.span(name);
    for (sdes_names) |e| {
        if (e.t != c.GST_RTCP_SDES_PRIV and std.mem.eql(u8, s, e.n)) return e.t;
    }
    return c.GST_RTCP_SDES_PRIV;
}

fn dataLength(p: [*c]Pkt) u16 {
    return rd16(base(p) + 2) -% 2;
}

fn setDataLength(p: [*c]Pkt, words: u16) c.gboolean {
    if (p[0].rtcp[0].map.maxsize < @as(usize, p[0].offset) + (@as(usize, words) + 3) * 4) return 0;
    const w = words +% 2;
    wr16(base(p) + 2, w);
    p[0].rtcp[0].map.size = p[0].offset + (@as(usize, w) + 1) * 4;
    return 1;
}

fn payload(p: [*c]Pkt) [*c]u8 {
    const d = base(p);
    return if (rd16(d + 2) <= 2) null else d + 12;
}

pub export fn gst_rtcp_packet_fb_get_fci_length(p: [*c]Pkt) c.guint16 {
    if (!guard(p, "gst_rtcp_packet_fb_get_fci_length", FB, R)) return 0;
    return dataLength(p);
}

pub export fn gst_rtcp_packet_fb_set_fci_length(p: [*c]Pkt, words: c.guint16) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_fb_set_fci_length", FB, W)) return 0;
    return setDataLength(p, words);
}

pub export fn gst_rtcp_packet_fb_get_fci(p: [*c]Pkt) [*c]u8 {
    if (!guard(p, "gst_rtcp_packet_fb_get_fci", FB, R)) return null;
    return payload(p);
}

pub export fn gst_rtcp_packet_app_set_subtype(p: [*c]Pkt, subtype: u8) void {
    if (!guard(p, "gst_rtcp_packet_app_set_subtype", APP, W)) return;
    const d = base(p);
    d[0] = (d[0] & 0xe0) | subtype;
}

pub export fn gst_rtcp_packet_app_get_subtype(p: [*c]Pkt) u8 {
    if (!guard(p, "gst_rtcp_packet_app_get_subtype", APP, R)) return 0;
    return base(p)[0] & 0x1f;
}

pub export fn gst_rtcp_packet_app_set_ssrc(p: [*c]Pkt, ssrc: c.guint32) void {
    if (!guard(p, "gst_rtcp_packet_app_set_ssrc", APP, W)) return;
    wr32(base(p) + 4, ssrc);
}

pub export fn gst_rtcp_packet_app_get_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_app_get_ssrc", APP, R)) return 0;
    return rd32(base(p) + 4);
}

pub export fn gst_rtcp_packet_app_set_name(p: [*c]Pkt, name: [*c]const u8) void {
    if (!guard(p, "gst_rtcp_packet_app_set_name", APP, W)) return;
    @memcpy((base(p) + 8)[0..4], name[0..4]);
}

pub export fn gst_rtcp_packet_app_get_name(p: [*c]Pkt) [*c]const u8 {
    if (!guard(p, "gst_rtcp_packet_app_get_name", APP, R)) return null;
    return base(p) + 8;
}

pub export fn gst_rtcp_packet_app_get_data_length(p: [*c]Pkt) c.guint16 {
    if (!guard(p, "gst_rtcp_packet_app_get_data_length", APP, R)) return 0;
    return dataLength(p);
}

pub export fn gst_rtcp_packet_app_set_data_length(p: [*c]Pkt, words: c.guint16) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_app_set_data_length", APP, W)) return 0;
    return setDataLength(p, words);
}

pub export fn gst_rtcp_packet_app_get_data(p: [*c]Pkt) [*c]u8 {
    if (!guard(p, "gst_rtcp_packet_app_get_data", APP, R)) return null;
    return payload(p);
}

pub export fn gst_rtcp_packet_xr_get_ssrc(p: [*c]Pkt) c.guint32 {
    if (!guard(p, "gst_rtcp_packet_xr_get_ssrc", XR, R)) return 0;
    return rd32(base(p) + 4);
}

pub export fn gst_rtcp_packet_xr_first_rb(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_xr_first_rb", XR, 0)) return 0;
    if (p[0].length < 2) return 0;
    p[0].item_offset = 8;
    const o = 8 + @as(c.guint, gst_rtcp_packet_xr_get_block_length(p)) + 4;
    if (o >= @as(c.guint, p[0].length) << 2) {
        p[0].item_offset = 0;
        return 0;
    }
    return 1;
}

pub export fn gst_rtcp_packet_xr_next_rb(p: [*c]Pkt) c.gboolean {
    if (!guard(p, "gst_rtcp_packet_xr_next_rb", XR, R)) return 0;
    const o = p[0].item_offset + (@as(c.guint, gst_rtcp_packet_xr_get_block_length(p)) + 1) * 4;
    if (o >= @as(c.guint, p[0].length) << 2) return 0;
    p[0].item_offset = o;
    return 1;
}

fn blockReady(p: [*c]Pkt, comptime f: []const u8) bool {
    if (!guard(p, f, XR, R)) return false;
    return that(p[0].length >= p[0].item_offset >> 2, f, "packet->length >= (packet->item_offset >> 2)");
}

pub export fn gst_rtcp_packet_xr_get_block_type(p: [*c]Pkt) c.GstRTCPXRType {
    if (!blockReady(p, "gst_rtcp_packet_xr_get_block_type")) return c.GST_RTCP_XR_TYPE_INVALID;
    const t = block(p)[0];
    return if (t >= c.GST_RTCP_XR_TYPE_LRLE and t <= c.GST_RTCP_XR_TYPE_VOIP_METRICS) t else c.GST_RTCP_XR_TYPE_INVALID;
}

pub export fn gst_rtcp_packet_xr_get_block_length(p: [*c]Pkt) c.guint16 {
    if (!blockReady(p, "gst_rtcp_packet_xr_get_block_length")) return 0;
    return rd16(block(p) + 2);
}

fn isBlock(p: [*c]Pkt, comptime f: []const u8, comptime t: c.GstRTCPXRType, comptime e: []const u8) bool {
    return that(gst_rtcp_packet_xr_get_block_type(p) == t, f, "gst_rtcp_packet_xr_get_block_type (packet) == " ++ e);
}

fn seqRange(d: [*c]u8, ssrc: [*c]u32, thinning: [*c]u8, begin: [*c]u16, end: [*c]u16) void {
    if (thinning != null) thinning.* = d[1] & 0x0f;
    if (ssrc != null) ssrc.* = rd32(d + 4);
    if (begin != null) begin.* = rd16(d + 8);
    if (end != null) end.* = rd16(d + 10);
}

pub export fn gst_rtcp_packet_xr_get_rle_info(p: [*c]Pkt, ssrc: [*c]c.guint32, thinning: [*c]u8, begin: [*c]c.guint16, end: [*c]c.guint16, chunks: [*c]c.guint32) c.gboolean {
    const f = "gst_rtcp_packet_xr_get_rle_info";
    const ok = gst_rtcp_packet_xr_get_block_type(p) == c.GST_RTCP_XR_TYPE_LRLE or gst_rtcp_packet_xr_get_block_type(p) == c.GST_RTCP_XR_TYPE_DRLE;
    if (!that(ok, f, "gst_rtcp_packet_xr_get_block_type (packet) == GST_RTCP_XR_TYPE_LRLE || gst_rtcp_packet_xr_get_block_type (packet) == GST_RTCP_XR_TYPE_DRLE")) return 0;
    const n = gst_rtcp_packet_xr_get_block_length(p);
    if (n < 3) return 0;
    if (chunks != null) chunks.* = (@as(u32, n) - 2) * 2;
    seqRange(block(p), ssrc, thinning, begin, end);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_rle_nth_chunk(p: [*c]Pkt, nth: c.guint, chunk: [*c]c.guint16) c.gboolean {
    var n: u32 = 0;
    if (gst_rtcp_packet_xr_get_rle_info(p, null, null, null, null, &n) == 0) {
        reached("gst_rtcp_packet_xr_get_rle_nth_chunk", 2896);
        return 0;
    }
    if (nth >= n) return 0;
    if (chunk != null) chunk.* = rd16(block(p) + 12 + nth * 2);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_prt_info(p: [*c]Pkt, ssrc: [*c]c.guint32, thinning: [*c]u8, begin: [*c]c.guint16, end: [*c]c.guint16) c.gboolean {
    if (!isBlock(p, "gst_rtcp_packet_xr_get_prt_info", c.GST_RTCP_XR_TYPE_PRT, "GST_RTCP_XR_TYPE_PRT")) return 0;
    if (gst_rtcp_packet_xr_get_block_length(p) < 3) return 0;
    seqRange(block(p), ssrc, thinning, begin, end);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_prt_by_seq(p: [*c]Pkt, seq: c.guint16, receipt: [*c]c.guint32) c.gboolean {
    var begin: u16 = 0;
    var end: u16 = 0;
    if (gst_rtcp_packet_xr_get_prt_info(p, null, null, &begin, &end) == 0) {
        reached("gst_rtcp_packet_xr_get_prt_by_seq", 2989);
        return 0;
    }
    if (seq >= end or seq < begin) return 0;
    if (receipt != null) receipt.* = rd32(block(p) + 12 + @as(usize, seq - begin) * 4);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_rrt(p: [*c]Pkt, timestamp: [*c]c.guint64) c.gboolean {
    if (!isBlock(p, "gst_rtcp_packet_xr_get_rrt", c.GST_RTCP_XR_TYPE_RRT, "GST_RTCP_XR_TYPE_RRT")) return 0;
    if (gst_rtcp_packet_xr_get_block_length(p) != 2) return 0;
    if (timestamp != null) timestamp.* = rd64(block(p) + 4);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_dlrr_block(p: [*c]Pkt, nth: c.guint, ssrc: [*c]c.guint32, last_rr: [*c]c.guint32, delay: [*c]c.guint32) c.gboolean {
    if (!isBlock(p, "gst_rtcp_packet_xr_get_dlrr_block", c.GST_RTCP_XR_TYPE_DLRR, "GST_RTCP_XR_TYPE_DLRR")) return 0;
    if (nth * 3 >= gst_rtcp_packet_xr_get_block_length(p)) return 0;
    const d = block(p) + 4 + nth * 12;
    if (ssrc != null) ssrc.* = rd32(d);
    if (last_rr != null) last_rr.* = rd32(d + 4);
    if (delay != null) delay.* = rd32(d + 8);
    return 1;
}

fn summary(p: [*c]Pkt, comptime f: []const u8) ?[*c]u8 {
    if (!isBlock(p, f, c.GST_RTCP_XR_TYPE_SSUMM, "GST_RTCP_XR_TYPE_SSUMM")) return null;
    if (gst_rtcp_packet_xr_get_block_length(p) != 9) return null;
    return block(p);
}

pub export fn gst_rtcp_packet_xr_get_summary_info(p: [*c]Pkt, ssrc: [*c]c.guint32, begin: [*c]c.guint16, end: [*c]c.guint16) c.gboolean {
    const d = summary(p, "gst_rtcp_packet_xr_get_summary_info") orelse return 0;
    seqRange(d, ssrc, null, begin, end);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_summary_pkt(p: [*c]Pkt, lost: [*c]c.guint32, dup: [*c]c.guint32) c.gboolean {
    const d = summary(p, "gst_rtcp_packet_xr_get_summary_pkt") orelse return 0;
    if (lost != null) lost.* = if (d[1] & 0x80 != 0) rd32(d + 12) else 0;
    if (dup != null) dup.* = if (d[1] & 0x40 != 0) rd32(d + 16) else 0;
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_summary_jitter(p: [*c]Pkt, min: [*c]c.guint32, max: [*c]c.guint32, mean: [*c]c.guint32, dev: [*c]c.guint32) c.gboolean {
    const d = summary(p, "gst_rtcp_packet_xr_get_summary_jitter") orelse return 0;
    const on = d[1] & 0x20 != 0;
    const outs = [_][*c]u32{ min, max, mean, dev };
    for (outs, 0..) |o, i| {
        if (o != null) o.* = if (on) rd32(d + 20 + i * 4) else 0;
    }
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_summary_ttl(p: [*c]Pkt, ipv4: [*c]c.gboolean, min: [*c]u8, max: [*c]u8, mean: [*c]u8, dev: [*c]u8) c.gboolean {
    const d = summary(p, "gst_rtcp_packet_xr_get_summary_ttl") orelse return 0;
    const kind = (d[1] & 0x18) >> 3;
    if (kind > 2) return 0;
    if (ipv4 != null) ipv4.* = @intFromBool(kind == 1);
    const outs = [_][*c]u8{ min, max, mean, dev };
    for (outs, 0..) |o, i| {
        if (o != null) o.* = d[36 + i];
    }
    return 1;
}

fn voip(p: [*c]Pkt, comptime f: []const u8) ?[*c]u8 {
    if (!isBlock(p, f, c.GST_RTCP_XR_TYPE_VOIP_METRICS, "GST_RTCP_XR_TYPE_VOIP_METRICS")) return null;
    if (gst_rtcp_packet_xr_get_block_length(p) != 8) return null;
    return block(p);
}

fn bytes4(d: [*c]u8, a: [*c]u8, b: [*c]u8, e: [*c]u8, g: [*c]u8) void {
    const outs = [_][*c]u8{ a, b, e, g };
    for (outs, 0..) |o, i| {
        if (o != null) o.* = d[i];
    }
}

pub export fn gst_rtcp_packet_xr_get_voip_metrics_ssrc(p: [*c]Pkt, ssrc: [*c]c.guint32) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_metrics_ssrc") orelse return 0;
    if (ssrc != null) ssrc.* = rd32(d + 4);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_packet_metrics(p: [*c]Pkt, loss: [*c]u8, discard: [*c]u8) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_packet_metrics") orelse return 0;
    bytes4(d + 8, loss, discard, null, null);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_burst_metrics(p: [*c]Pkt, burst_density: [*c]u8, gap_density: [*c]u8, burst_duration: [*c]c.guint16, gap_duration: [*c]c.guint16) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_burst_metrics") orelse return 0;
    bytes4(d + 10, burst_density, gap_density, null, null);
    if (burst_duration != null) burst_duration.* = rd16(d + 12);
    if (gap_duration != null) gap_duration.* = rd16(d + 14);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_delay_metrics(p: [*c]Pkt, roundtrip: [*c]c.guint16, end_system: [*c]c.guint16) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_delay_metrics") orelse return 0;
    if (roundtrip != null) roundtrip.* = rd16(d + 16);
    if (end_system != null) end_system.* = rd16(d + 18);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_signal_metrics(p: [*c]Pkt, signal: [*c]u8, noise: [*c]u8, rerl: [*c]u8, gmin: [*c]u8) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_signal_metrics") orelse return 0;
    bytes4(d + 20, signal, noise, rerl, gmin);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_quality_metrics(p: [*c]Pkt, r: [*c]u8, ext_r: [*c]u8, mos_lq: [*c]u8, mos_cq: [*c]u8) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_quality_metrics") orelse return 0;
    bytes4(d + 24, r, ext_r, mos_lq, mos_cq);
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_configuration_params(p: [*c]Pkt, gmin: [*c]u8, rx_config: [*c]u8) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_configuration_params") orelse return 0;
    if (gmin != null) gmin.* = d[23];
    if (rx_config != null) rx_config.* = d[28];
    return 1;
}

pub export fn gst_rtcp_packet_xr_get_voip_jitter_buffer_params(p: [*c]Pkt, nominal: [*c]c.guint16, maximum: [*c]c.guint16, abs_max: [*c]c.guint16) c.gboolean {
    const d = voip(p, "gst_rtcp_packet_xr_get_voip_jitter_buffer_params") orelse return 0;
    if (nominal != null) nominal.* = rd16(d + 30);
    if (maximum != null) maximum.* = rd16(d + 32);
    if (abs_max != null) abs_max.* = rd16(d + 34);
    return 1;
}
