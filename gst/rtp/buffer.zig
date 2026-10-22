const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const payloads = @import("payloads.zig");

comptime {
    @import("../abi.zig").check(@This());
}

pub const DOMAIN = "GStreamer-RTP";
const HEADER_LEN = 12;
const Rtp = c.GstRTPBuffer;
const N: ?*anyopaque = null;

pub fn that(ok: bool, comptime func: []const u8, comptime expr: []const u8) bool {
    if (!ok) c.g_log(DOMAIN, c.G_LOG_LEVEL_CRITICAL, "%s: assertion '%s' failed", @as([*c]const u8, func ++ ""), @as([*c]const u8, expr ++ ""));
    return ok;
}

pub fn isBuffer(b: anytype) bool {
    return b != null and @as(*const c.GstMiniObject, @ptrCast(@alignCast(b))).type == c.gst_buffer_get_type();
}

pub fn writable(b: anytype) bool {
    return c.gst_mini_object_is_writable(@ptrCast(b)) != 0;
}

fn h(rtp: [*c]Rtp) [*c]u8 {
    return @ptrCast(rtp[0].data[0]);
}

fn setBit(p: [*c]u8, mask: u8, on: bool) void {
    if (on) {
        p[0] |= mask;
    } else p[0] &= ~mask;
}

fn rd16(p: [*c]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .big);
}

fn rd32(p: [*c]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .big);
}

fn wr16(p: [*c]u8, v: u16) void {
    std.mem.writeInt(u16, p[0..2], v, .big);
}

fn wr32(p: [*c]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .big);
}

pub export fn gst_rtp_buffer_allocate_data(buffer: [*c]c.GstBuffer, payload_len: c.guint, pad_len: u8, csrc_count: u8) void {
    const f = "gst_rtp_buffer_allocate_data";
    if (!that(csrc_count <= 15, f, "csrc_count <= 15")) return;
    if (!that(isBuffer(buffer), f, "GST_IS_BUFFER (buffer)")) return;
    if (!that(writable(buffer), f, "gst_buffer_is_writable (buffer)")) return;
    c.gst_buffer_remove_all_memory(buffer);
    const hlen: usize = HEADER_LEN + @as(usize, csrc_count) * 4;
    var mem = c.gst_allocator_alloc(null, hlen, null);
    var map: c.GstMapInfo = undefined;
    _ = c.gst_memory_map(mem, &map, c.GST_MAP_WRITE);
    const d: [*c]u8 = map.data;
    d[0] = (2 << 6) | (if (pad_len != 0) @as(u8, 0x20) else 0) | csrc_count;
    d[1] = 0;
    @memset(d[2..12], 0);
    @memset(d[12..hlen], 0);
    c.gst_memory_unmap(mem, &map);
    c.gst_buffer_append_memory(buffer, mem);
    if (payload_len != 0) {
        mem = c.gst_allocator_alloc(null, payload_len, null);
        c.gst_buffer_append_memory(buffer, mem);
    }
    if (pad_len != 0) {
        mem = c.gst_allocator_alloc(null, pad_len, null);
        _ = c.gst_memory_map(mem, &map, c.GST_MAP_WRITE);
        map.data[pad_len - 1] = pad_len;
        c.gst_memory_unmap(mem, &map);
        c.gst_buffer_append_memory(buffer, mem);
    }
}

pub export fn gst_rtp_buffer_new_take_data(data: c.gpointer, len: c.gsize) [*c]c.GstBuffer {
    if (!that(data != null, "gst_rtp_buffer_new_take_data", "data != NULL")) return null;
    if (!that(len > 0, "gst_rtp_buffer_new_take_data", "len > 0")) return null;
    return c.gst_buffer_new_wrapped(data, len);
}

pub export fn gst_rtp_buffer_new_copy_data(data: c.gconstpointer, len: c.gsize) [*c]c.GstBuffer {
    return gst_rtp_buffer_new_take_data(c.g_memdup2(data, len), len);
}

pub export fn gst_rtp_buffer_new_allocate(payload_len: c.guint, pad_len: u8, csrc_count: u8) [*c]c.GstBuffer {
    if (!that(csrc_count <= 15, "gst_rtp_buffer_new_allocate", "csrc_count <= 15")) return null;
    const r = c.gst_buffer_new();
    gst_rtp_buffer_allocate_data(r, payload_len, pad_len, csrc_count);
    return r;
}

pub export fn gst_rtp_buffer_new_allocate_len(packet_len: c.guint, pad_len: u8, csrc_count: u8) [*c]c.GstBuffer {
    if (!that(csrc_count <= 15, "gst_rtp_buffer_new_allocate_len", "csrc_count <= 15")) return null;
    return gst_rtp_buffer_new_allocate(gst_rtp_buffer_calc_payload_len(packet_len, pad_len, csrc_count), pad_len, csrc_count);
}

pub export fn gst_rtp_buffer_calc_header_len(csrc_count: u8) c.guint {
    if (!that(csrc_count <= 15, "gst_rtp_buffer_calc_header_len", "csrc_count <= 15")) return 0;
    return HEADER_LEN + @as(c.guint, csrc_count) * 4;
}

pub export fn gst_rtp_buffer_calc_packet_len(payload_len: c.guint, pad_len: u8, csrc_count: u8) c.guint {
    if (!that(csrc_count <= 15, "gst_rtp_buffer_calc_packet_len", "csrc_count <= 15")) return 0;
    return payload_len +% HEADER_LEN +% @as(c.guint, csrc_count) * 4 +% pad_len;
}

pub export fn gst_rtp_buffer_calc_payload_len(packet_len: c.guint, pad_len: u8, csrc_count: u8) c.guint {
    if (!that(csrc_count <= 15, "gst_rtp_buffer_calc_payload_len", "csrc_count <= 15")) return 0;
    const over = HEADER_LEN + @as(c.guint, csrc_count) * 4 + pad_len;
    if (packet_len < over) return 0;
    return packet_len - over;
}

fn dumpFail(buffer: [*c]c.GstBuffer, rtp: [*c]Rtp) c.gboolean {
    for (&rtp[0].map) |*m| {
        if (m.memory != null) c.gst_buffer_unmap(buffer, m);
    }
    return 0;
}

pub export fn gst_rtp_buffer_map(buffer: [*c]c.GstBuffer, flags: c.GstMapFlags, rtp: [*c]Rtp) c.gboolean {
    const f = "gst_rtp_buffer_map";
    if (!that(isBuffer(buffer), f, "GST_IS_BUFFER (buffer)")) return 0;
    if (!that(rtp != null, f, "rtp != NULL")) return 0;
    if (!that(rtp[0].buffer == null, f, "rtp->buffer == NULL")) return 0;
    const n_mem = c.gst_buffer_n_memory(buffer);
    if (n_mem < 1) return 0;
    if (c.gst_buffer_map_range(buffer, 0, 1, &rtp[0].map[0], flags) == 0) return 0;
    const data: [*c]u8 = rtp[0].map[0].data;
    rtp[0].data[0] = data;
    const size = rtp[0].map[0].size;
    var header_len: c.guint = HEADER_LEN;
    if (size < header_len) return dumpFail(buffer, rtp);
    if ((data[0] & 0xc0) != (2 << 6)) return dumpFail(buffer, rtp);
    const pt = data[1];
    if (pt >= 200 and pt <= 204) return dumpFail(buffer, rtp);
    header_len += @as(c.guint, data[0] & 0x0f) * 4;
    rtp[0].size[0] = header_len;
    const bufsize = c.gst_buffer_get_size(buffer);
    if (header_len > bufsize) return dumpFail(buffer, rtp);
    var idx: c.guint = 0;
    var length: c.guint = 0;
    var skip: usize = 0;
    if (data[0] & 0x10 != 0) {
        if (c.gst_buffer_find_memory(buffer, header_len, 4, &idx, &length, &skip) == 0) return dumpFail(buffer, rtp);
        if (c.gst_buffer_map_range(buffer, idx, @intCast(length), &rtp[0].map[1], flags) == 0) return 0;
        const ext: [*c]u8 = rtp[0].map[1].data + skip;
        rtp[0].data[1] = ext;
        var extlen: usize = rd16(ext + 2);
        extlen *= 4;
        extlen += 4;
        if (rtp[0].map[1].size < extlen) return dumpFail(buffer, rtp);
        rtp[0].size[1] = @intCast(extlen);
        header_len +%= @intCast(rtp[0].size[1]);
    } else {
        rtp[0].data[1] = null;
        rtp[0].size[1] = 0;
    }
    var padding: u8 = 0;
    if (data[0] & 0x20 != 0 and (flags & c.GST_RTP_BUFFER_MAP_FLAG_SKIP_PADDING) == 0) {
        if (c.gst_buffer_find_memory(buffer, bufsize - 1, 1, &idx, &length, &skip) == 0) return dumpFail(buffer, rtp);
        if (c.gst_buffer_map_range(buffer, idx, @intCast(length), &rtp[0].map[3], flags) == 0) return 0;
        padding = rtp[0].map[3].data[skip];
        rtp[0].data[3] = rtp[0].map[3].data + skip + 1 - padding;
        rtp[0].size[3] = padding;
        if (skip + 1 < padding) return dumpFail(buffer, rtp);
    } else {
        rtp[0].data[3] = null;
        rtp[0].size[3] = 0;
    }
    if (bufsize < @as(usize, padding) + header_len) return dumpFail(buffer, rtp);
    rtp[0].buffer = buffer;
    if (n_mem == 1) {
        rtp[0].data[2] = rtp[0].map[0].data + header_len;
        rtp[0].size[2] = @intCast(bufsize - header_len - padding);
    } else {
        rtp[0].data[2] = null;
        rtp[0].size[2] = 0;
    }
    return 1;
}

pub export fn gst_rtp_buffer_unmap(rtp: [*c]Rtp) void {
    if (!that(rtp != null, "gst_rtp_buffer_unmap", "rtp != NULL")) return;
    if (!that(rtp[0].buffer != null, "gst_rtp_buffer_unmap", "rtp->buffer != NULL")) return;
    for (0..4) |i| {
        if (rtp[0].map[i].memory != null) {
            c.gst_buffer_unmap(rtp[0].buffer, &rtp[0].map[i]);
            rtp[0].map[i].memory = null;
        }
        rtp[0].data[i] = null;
        rtp[0].size[i] = 0;
    }
    rtp[0].buffer = null;
}

pub export fn gst_rtp_buffer_set_packet_len(rtp: [*c]Rtp, len: c.guint) void {
    const d = h(rtp);
    if (rtp[0].map[0].maxsize <= len) c.g_log(DOMAIN, c.G_LOG_LEVEL_WARNING, "not implemented");
    c.gst_buffer_set_size(rtp[0].buffer, len);
    rtp[0].map[0].size = len;
    setBit(d, 0x20, false);
}

pub export fn gst_rtp_buffer_get_packet_len(rtp: [*c]Rtp) c.guint {
    return @truncate(c.gst_buffer_get_size(rtp[0].buffer));
}

pub export fn gst_rtp_buffer_get_header_len(rtp: [*c]Rtp) c.guint {
    return @intCast(rtp[0].size[0] +% rtp[0].size[1]);
}

pub export fn gst_rtp_buffer_get_version(rtp: [*c]Rtp) u8 {
    return h(rtp)[0] >> 6;
}

pub export fn gst_rtp_buffer_set_version(rtp: [*c]Rtp, v: u8) void {
    if (!that(v < 0x04, "gst_rtp_buffer_set_version", "version < 0x04")) return;
    const d = h(rtp);
    d[0] = (d[0] & 0x3f) | (v << 6);
}

pub export fn gst_rtp_buffer_get_padding(rtp: [*c]Rtp) c.gboolean {
    return (h(rtp)[0] >> 5) & 1;
}

pub export fn gst_rtp_buffer_set_padding(rtp: [*c]Rtp, padding: c.gboolean) void {
    setBit(h(rtp), 0x20, padding & 1 != 0);
}

pub export fn gst_rtp_buffer_pad_to(rtp: [*c]Rtp, len: c.guint) void {
    setBit(h(rtp), 0x20, len > 0);
}

pub export fn gst_rtp_buffer_get_extension(rtp: [*c]Rtp) c.gboolean {
    return (h(rtp)[0] >> 4) & 1;
}

pub export fn gst_rtp_buffer_set_extension(rtp: [*c]Rtp, ext: c.gboolean) void {
    setBit(h(rtp), 0x10, ext & 1 != 0);
}

pub export fn gst_rtp_buffer_get_extension_data(rtp: [*c]Rtp, bits: [*c]c.guint16, data: [*c]c.gpointer, wordlen: [*c]c.guint) c.gboolean {
    const p: [*c]u8 = @ptrCast(rtp[0].data[1]);
    if (p == null) return 0;
    if (bits != null) bits.* = rd16(p);
    if (wordlen != null) wordlen.* = rd16(p + 2);
    if (data != null) data.* = p + 4;
    return 1;
}

pub export fn gst_rtp_buffer_get_extension_bytes(rtp: [*c]Rtp, bits: [*c]c.guint16) ?*c.GBytes {
    if (!that(rtp != null, "gst_rtp_buffer_get_extension_bytes", "rtp != NULL")) return null;
    var d: c.gpointer = null;
    var len: c.guint = 0;
    if (gst_rtp_buffer_get_extension_data(rtp, bits, &d, &len) == 0) return null;
    if (len == 0) d = null;
    return c.g_bytes_new(d, 4 * @as(usize, len));
}

fn mapPayload(rtp: [*c]Rtp) bool {
    if (rtp[0].map[2].memory != null) return true;
    const hlen = gst_rtp_buffer_get_header_len(rtp);
    const plen = c.gst_buffer_get_size(rtp[0].buffer) -% hlen -% rtp[0].size[3];
    var idx: c.guint = 0;
    var length: c.guint = 0;
    var skip: usize = 0;
    if (c.gst_buffer_find_memory(rtp[0].buffer, hlen, plen, &idx, &length, &skip) == 0) return false;
    if (c.gst_buffer_map_range(rtp[0].buffer, idx, @intCast(length), &rtp[0].map[2], rtp[0].map[0].flags) == 0) return false;
    rtp[0].data[2] = rtp[0].map[2].data + skip;
    rtp[0].size[2] = @truncate(plen);
    return true;
}

fn ensureBuffers(rtp: [*c]Rtp) void {
    _ = mapPayload(rtp);
    var changed = false;
    var pos: c.guint = 0;
    for (0..4) |i| {
        if (rtp[0].size[i] == 0) continue;
        const offset = @intFromPtr(rtp[0].data[i]) -% @intFromPtr(rtp[0].map[i].data);
        if (offset != 0 or rtp[0].map[i].size != rtp[0].size[i]) {
            const mem = c.gst_memory_copy(rtp[0].map[i].memory, @bitCast(offset), @intCast(rtp[0].size[i]));
            c.gst_buffer_insert_memory(rtp[0].buffer, @bitCast(pos), mem);
            changed = true;
        }
        pos += 1;
    }
    if (changed) {
        const buf = rtp[0].buffer;
        gst_rtp_buffer_unmap(rtp);
        c.gst_buffer_remove_memory_range(buf, pos, -1);
        _ = gst_rtp_buffer_map(buf, c.GST_MAP_READWRITE, rtp);
    }
}

pub export fn gst_rtp_buffer_set_extension_data(rtp: [*c]Rtp, bits: c.guint16, length: c.guint16) c.gboolean {
    if (!that(writable(rtp[0].buffer), "gst_rtp_buffer_set_extension_data", "gst_buffer_is_writable (rtp->buffer)")) return 0;
    ensureBuffers(rtp);
    const min_size: u32 = 4 + @as(u32, length) * 4;
    if (rtp[0].data[1] == null or min_size != rtp[0].size[1]) {
        var map: c.GstMapInfo = undefined;
        if (rtp[0].data[1] == null or min_size > rtp[0].size[1]) {
            const mem = c.gst_allocator_alloc(null, min_size, null);
            if (rtp[0].data[1] != null) {
                _ = c.gst_memory_map(mem, &map, c.GST_MAP_WRITE);
                const old: [*c]const u8 = @ptrCast(rtp[0].data[1]);
                @memcpy(map.data[0..rtp[0].size[1]], old[0..rtp[0].size[1]]);
                if (min_size > rtp[0].size[1]) @memset(map.data[rtp[0].size[1]..min_size], 0);
                c.gst_memory_unmap(mem, &map);
                c.gst_buffer_unmap(rtp[0].buffer, &rtp[0].map[1]);
                c.gst_buffer_replace_memory(rtp[0].buffer, 1, mem);
            } else {
                _ = c.gst_memory_map(mem, &map, c.GST_MAP_WRITE);
                @memset(map.data[0..map.size], 0);
                c.gst_memory_unmap(mem, &map);
                c.gst_buffer_insert_memory(rtp[0].buffer, 1, mem);
            }
        } else if (min_size < rtp[0].size[1]) {
            const mem = rtp[0].map[1].memory;
            c.gst_buffer_unmap(rtp[0].buffer, &rtp[0].map[1]);
            c.gst_memory_resize(mem, 0, min_size);
        }
        if (c.gst_buffer_map_range(rtp[0].buffer, 1, 1, &rtp[0].map[1], c.GST_MAP_READWRITE) == 0) unreachable;
        rtp[0].data[1] = rtp[0].map[1].data;
        rtp[0].size[1] = @intCast(rtp[0].map[1].size);
    }
    setBit(h(rtp), 0x10, true);
    const d: [*c]u8 = @ptrCast(rtp[0].data[1]);
    wr16(d, bits);
    wr16(d + 2, length);
    return 1;
}

pub export fn gst_rtp_buffer_remove_extension_data(rtp: [*c]Rtp) void {
    const f = "gst_rtp_buffer_remove_extension_data";
    if (!that(writable(rtp[0].buffer), f, "gst_buffer_is_writable (rtp->buffer)")) return;
    if (!that(rtp[0].map[0].flags & c.GST_MAP_WRITE != 0, f, "rtp->map[0].flags & GST_MAP_WRITE")) return;
    if (rtp[0].data[1] == null) return;
    const buf = rtp[0].buffer;
    ensureBuffers(rtp);
    setBit(h(rtp), 0x10, false);
    gst_rtp_buffer_unmap(rtp);
    c.gst_buffer_remove_memory(buf, 1);
    _ = gst_rtp_buffer_map(buf, c.GST_MAP_READWRITE, rtp);
}

pub export fn gst_rtp_buffer_get_ssrc(rtp: [*c]Rtp) c.guint32 {
    return rd32(h(rtp) + 8);
}

pub export fn gst_rtp_buffer_set_ssrc(rtp: [*c]Rtp, v: c.guint32) void {
    wr32(h(rtp) + 8, v);
}

pub export fn gst_rtp_buffer_get_csrc_count(rtp: [*c]Rtp) u8 {
    return h(rtp)[0] & 0x0f;
}

pub export fn gst_rtp_buffer_get_csrc(rtp: [*c]Rtp, idx: u8) c.guint32 {
    const d = h(rtp);
    if (!that(idx < (d[0] & 0x0f), "gst_rtp_buffer_get_csrc", "idx < GST_RTP_HEADER_CSRC_COUNT (data)")) return 0;
    return rd32(d + 12 + @as(usize, idx) * 4);
}

pub export fn gst_rtp_buffer_set_csrc(rtp: [*c]Rtp, idx: u8, v: c.guint32) void {
    const d = h(rtp);
    if (!that(idx < (d[0] & 0x0f), "gst_rtp_buffer_set_csrc", "idx < GST_RTP_HEADER_CSRC_COUNT (data)")) return;
    wr32(d + 12 + @as(usize, idx) * 4, v);
}

pub export fn gst_rtp_buffer_get_marker(rtp: [*c]Rtp) c.gboolean {
    return h(rtp)[1] >> 7;
}

pub export fn gst_rtp_buffer_set_marker(rtp: [*c]Rtp, marker: c.gboolean) void {
    const d = h(rtp);
    d[1] = (d[1] & 0x7f) | (@as(u8, @truncate(@as(c_uint, @bitCast(marker)) & 1)) << 7);
}

pub export fn gst_rtp_buffer_get_payload_type(rtp: [*c]Rtp) u8 {
    return h(rtp)[1] & 0x7f;
}

pub export fn gst_rtp_buffer_set_payload_type(rtp: [*c]Rtp, pt: u8) void {
    if (!that(pt < 0x80, "gst_rtp_buffer_set_payload_type", "payload_type < 0x80")) return;
    const d = h(rtp);
    d[1] = (d[1] & 0x80) | pt;
}

pub export fn gst_rtp_buffer_get_seq(rtp: [*c]Rtp) c.guint16 {
    return rd16(h(rtp) + 2);
}

pub export fn gst_rtp_buffer_set_seq(rtp: [*c]Rtp, seq: c.guint16) void {
    wr16(h(rtp) + 2, seq);
}

pub export fn gst_rtp_buffer_get_timestamp(rtp: [*c]Rtp) c.guint32 {
    return rd32(h(rtp) + 4);
}

pub export fn gst_rtp_buffer_set_timestamp(rtp: [*c]Rtp, ts: c.guint32) void {
    wr32(h(rtp) + 4, ts);
}

pub export fn gst_rtp_buffer_get_payload_subbuffer(rtp: [*c]Rtp, offset: c.guint, len: c.guint) [*c]c.GstBuffer {
    var plen = gst_rtp_buffer_get_payload_len(rtp);
    if (offset > plen) {
        c.g_log(DOMAIN, c.G_LOG_LEVEL_WARNING, "offset=%u should be less than plen=%u", offset, plen);
        return null;
    }
    const poffset = gst_rtp_buffer_get_header_len(rtp) +% offset;
    plen -= offset;
    if (len != std.math.maxInt(c.guint) and len < plen) plen = len;
    return c.gst_buffer_copy_region(rtp[0].buffer, c.GST_BUFFER_COPY_ALL, poffset, plen);
}

pub export fn gst_rtp_buffer_get_payload_buffer(rtp: [*c]Rtp) [*c]c.GstBuffer {
    return gst_rtp_buffer_get_payload_subbuffer(rtp, 0, std.math.maxInt(c.guint));
}

pub export fn gst_rtp_buffer_get_payload_len(rtp: [*c]Rtp) c.guint {
    return @truncate(c.gst_buffer_get_size(rtp[0].buffer) -% gst_rtp_buffer_get_header_len(rtp) -% rtp[0].size[3]);
}

pub export fn gst_rtp_buffer_get_payload(rtp: [*c]Rtp) c.gpointer {
    if (rtp[0].data[2] != null) return rtp[0].data[2];
    if (!mapPayload(rtp)) return null;
    return rtp[0].data[2];
}

pub export fn gst_rtp_buffer_get_payload_bytes(rtp: [*c]Rtp) ?*c.GBytes {
    if (!that(rtp != null, "gst_rtp_buffer_get_payload_bytes", "rtp != NULL")) return null;
    const d = gst_rtp_buffer_get_payload(rtp);
    if (d == null) return null;
    return c.g_bytes_new(d, gst_rtp_buffer_get_payload_len(rtp));
}

pub export fn gst_rtp_buffer_default_clock_rate(pt: u8) c.guint32 {
    const info = payloads.gst_rtp_payload_info_for_pt(pt);
    if (info == null) return std.math.maxInt(u32);
    const r = info[0].clock_rate;
    return if (r == 0) std.math.maxInt(u32) else r;
}

pub export fn gst_rtp_buffer_compare_seqnum(a: c.guint16, b: c.guint16) c.gint {
    return @as(i16, @bitCast(b -% a));
}

pub export fn gst_rtp_buffer_ext_timestamp(ext_ts: [*c]c.guint64, ts: c.guint32) c.guint64 {
    if (!that(ext_ts != null, "gst_rtp_buffer_ext_timestamp", "exttimestamp != NULL")) return std.math.maxInt(u64);
    const ext = ext_ts.*;
    var result: u64 = 0;
    if (ext == std.math.maxInt(u64)) {
        result = (@as(u64, 1) << 32) + ts;
    } else {
        result = ts + (ext & ~@as(u64, 0xffffffff));
        if (result < ext) {
            if (ext - result > std.math.maxInt(i32)) result += @as(u64, 1) << 32;
        } else if (result - ext > std.math.maxInt(i32)) {
            if (result < (@as(u64, 1) << 32)) return 0;
            return result - (@as(u64, 1) << 32);
        }
    }
    ext_ts.* = result;
    return result;
}

fn onebyte(pdata: [*c]const u8, len: usize, pattern: u16, id: u8, nth: c.guint, data: [*c]c.gpointer, size: [*c]c.guint) c.gboolean {
    if (!that(id > 0 and id < 15, "_get_extension_onebyte_header", "id > 0 && id < 15")) return 0;
    if (pattern != 0xBEDE) return 0;
    var offset: usize = 0;
    var count: c.guint = 0;
    while (true) {
        if (offset + 1 >= len) break;
        const rid = pdata[offset] >> 4;
        const rlen: usize = @as(usize, pdata[offset] & 0x0f) + 1;
        offset += 1;
        if (rid == 0) continue;
        if (rid == 15) break;
        if (offset + rlen > len) break;
        if (id == rid) {
            if (nth == count) {
                if (data != null) data.* = @constCast(pdata + offset);
                if (size != null) size.* = @intCast(rlen);
                return 1;
            }
            count += 1;
        }
        offset += rlen;
        if (offset >= len) break;
    }
    return 0;
}

pub export fn gst_rtp_buffer_get_extension_onebyte_header_from_bytes(bytes: ?*c.GBytes, pattern: c.guint16, id: u8, nth: c.guint, data: [*c]c.gpointer, size: [*c]c.guint) c.gboolean {
    const p: [*c]const u8 = @ptrCast(c.g_bytes_get_data(bytes, null));
    return onebyte(p, c.g_bytes_get_size(bytes), pattern, id, nth, data, size);
}

pub export fn gst_rtp_buffer_get_extension_onebyte_header(rtp: [*c]Rtp, id: u8, nth: c.guint, data: [*c]c.gpointer, size: [*c]c.guint) c.gboolean {
    var bits: u16 = 0;
    var p: c.gpointer = null;
    var wl: c.guint = 0;
    if (gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl) == 0) return 0;
    return onebyte(@ptrCast(p), @as(usize, wl) * 4, bits, id, nth, data, size);
}

pub export fn gst_rtp_buffer_get_extension_twobytes_header(rtp: [*c]Rtp, appbits: [*c]u8, id: u8, nth: c.guint, data: [*c]c.gpointer, size: [*c]c.guint) c.gboolean {
    var bits: u16 = 0;
    var p: c.gpointer = null;
    var wl: c.guint = 0;
    if (gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl) == 0) return 0;
    if (bits >> 4 != 0x100) return 0;
    const pd: [*c]u8 = @ptrCast(p);
    const bytelen: usize = @as(usize, wl) * 4;
    var offset: usize = 0;
    var count: c.guint = 0;
    while (true) {
        if (offset + 2 >= bytelen) break;
        const rid = pd[offset];
        offset += 1;
        if (rid == 0) continue;
        const rlen: usize = pd[offset];
        offset += 1;
        if (offset + rlen > bytelen) break;
        if (id == rid) {
            if (nth == count) {
                if (data != null) data.* = pd + offset;
                if (size != null) size.* = @intCast(rlen);
                if (appbits != null) appbits.* = @truncate(bits);
                return 1;
            }
            count += 1;
        }
        offset += rlen;
    }
    return 0;
}

fn onebyteEnd(pd: [*c]const u8, wl: c.guint, offset: *c.guint) bool {
    const bytelen = wl * 4;
    var pad: c.guint = 0;
    offset.* = 0;
    while (offset.* + 1 < bytelen) {
        const rid = pd[offset.*] >> 4;
        const rlen: c.guint = @as(c.guint, pd[offset.*] & 0x0f) + 1;
        offset.* += 1;
        if (rid == 0) {
            pad += 1;
            continue;
        }
        pad = 0;
        if (rid == 15) return false;
        if (offset.* + rlen > bytelen) return false;
        offset.* += rlen;
    }
    offset.* -%= pad;
    return true;
}

pub export fn gst_rtp_buffer_add_extension_onebyte_header(rtp: [*c]Rtp, id: u8, data: c.gconstpointer, size: c.guint) c.gboolean {
    const f = "gst_rtp_buffer_add_extension_onebyte_header";
    if (!that(id > 0 and id < 15, f, "id > 0 && id < 15")) return 0;
    if (!that(size >= 1 and size <= 16, f, "size >= 1 && size <= 16")) return 0;
    if (!that(writable(rtp[0].buffer), f, "gst_buffer_is_writable (rtp->buffer)")) return 0;
    var bits: u16 = 0;
    var p: c.gpointer = null;
    var wl: c.guint = 0;
    var offset: c.guint = 0;
    if (gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl) != 0) {
        if (bits != 0xBEDE) return 0;
        if (!onebyteEnd(@ptrCast(p), wl, &offset)) return 0;
    }
    const extlen = offset + size + 1;
    var wl_new = extlen / 4 + @intFromBool(extlen % 4 != 0);
    wl_new = @max(wl_new, wl);
    _ = gst_rtp_buffer_set_extension_data(rtp, 0xBEDE, @truncate(wl_new));
    _ = gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl);
    const pd: [*c]u8 = @as([*c]u8, @ptrCast(p)) + offset;
    pd[0] = (id << 4) | @as(u8, @truncate(0x0f & (size - 1)));
    @memcpy(pd[1..][0..size], @as([*c]const u8, @ptrCast(data))[0..size]);
    if (extlen % 4 != 0) @memset(pd[1 + size ..][0 .. 4 - (extlen % 4)], 0);
    return 1;
}

fn twobyteEnd(pd: [*c]const u8, wl: c.guint) c.guint {
    var offset: c.guint = 0;
    const bytelen = wl * 4;
    var pad: c.guint = 0;
    while (offset + 2 < bytelen) {
        const rid = pd[offset];
        offset += 1;
        if (rid == 0) {
            pad += 1;
            continue;
        }
        pad = 0;
        const rlen: c.guint = pd[offset];
        offset += 1;
        if (offset + rlen > bytelen) return 0;
        offset += rlen;
    }
    return offset -% pad;
}

pub export fn gst_rtp_buffer_add_extension_twobytes_header(rtp: [*c]Rtp, appbits: u8, id: u8, data: c.gconstpointer, size: c.guint) c.gboolean {
    const f = "gst_rtp_buffer_add_extension_twobytes_header";
    if (!that(appbits & 0xf0 == 0, f, "(appbits & 0xF0) == 0")) return 0;
    if (!that(size < 256, f, "size < 256")) return 0;
    if (!that(writable(rtp[0].buffer), f, "gst_buffer_is_writable (rtp->buffer)")) return 0;
    var bits: u16 = 0;
    var p: c.gpointer = null;
    var wl: c.guint = 0;
    var offset: c.guint = 0;
    const want: u16 = (@as(u16, 0x100) << 4) | (appbits & 0x0f);
    if (gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl) != 0) {
        if (bits != want) return 0;
        offset = twobyteEnd(@ptrCast(p), wl);
        if (offset == 0) return 0;
    }
    const extlen = offset + size + 2;
    wl = extlen / 4 + @intFromBool(extlen % 4 != 0);
    _ = gst_rtp_buffer_set_extension_data(rtp, want, @truncate(wl));
    _ = gst_rtp_buffer_get_extension_data(rtp, &bits, &p, &wl);
    const pd: [*c]u8 = @as([*c]u8, @ptrCast(p)) + offset;
    pd[0] = id;
    pd[1] = @truncate(size);
    @memcpy(pd[2..][0..size], @as([*c]const u8, @ptrCast(data))[0..size]);
    if (extlen % 4 != 0) @memset(pd[2 + size ..][0 .. 4 - (extlen % 4)], 0);
    return 1;
}
