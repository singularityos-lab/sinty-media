const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const that = @import("buffer.zig").that;

comptime {
    @import("../abi.zig").check(@This());
}

const Meta = c.GstRTPSourceMeta;
const MAX = c.GST_RTP_SOURCE_META_MAX_CSRC_COUNT;

var api_once: gtype.Once = .{};
var info: ?*const c.GstMetaInfo = null;
var info_lock: gtype.Lock = .{};

pub export fn gst_buffer_add_rtp_source_meta(b: [*c]c.GstBuffer, ssrc: [*c]const c.guint32, csrc: [*c]const c.guint, count: c.guint) [*c]Meta {
    const f = "gst_buffer_add_rtp_source_meta";
    if (!that(b != null, f, "buffer != NULL")) return null;
    if (!that(count <= MAX, f, "csrc_count <= GST_RTP_SOURCE_META_MAX_CSRC_COUNT")) return null;
    if (!that(count == 0 or csrc != null, f, "csrc_count == 0 || csrc != NULL")) return null;
    const m: [*c]Meta = @ptrCast(@alignCast(c.gst_buffer_add_meta(b, gst_rtp_source_meta_get_info(), null)));
    if (m == null) return null;
    if (ssrc != null) {
        m[0].ssrc = ssrc.*;
        m[0].ssrc_valid = 1;
    } else m[0].ssrc_valid = 0;
    m[0].csrc_count = count;
    for (0..count) |i| m[0].csrc[i] = csrc[i];
    return m;
}

pub export fn gst_buffer_get_rtp_source_meta(b: [*c]c.GstBuffer) [*c]Meta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(b, gst_rtp_source_meta_api_get_type())));
}

fn transform(dst: [*c]c.GstBuffer, meta: [*c]c.GstMeta, _: [*c]c.GstBuffer, kind: c.GQuark, _: c.gpointer) callconv(.c) c.gboolean {
    if (kind != c._gst_meta_transform_copy) return 0;
    const s: [*c]Meta = @ptrCast(@alignCast(meta));
    const ssrc: [*c]const u32 = if (s[0].ssrc_valid != 0) &s[0].ssrc else null;
    return @intFromBool(gst_buffer_add_rtp_source_meta(dst, ssrc, &s[0].csrc, s[0].csrc_count) != null);
}

pub export fn gst_rtp_source_meta_get_source_count(m: [*c]const Meta) c.guint {
    return @min(m[0].csrc_count + @as(c.guint, @intFromBool(m[0].ssrc_valid != 0)), 15);
}

pub export fn gst_rtp_source_meta_set_ssrc(m: [*c]Meta, ssrc: [*c]c.guint32) c.gboolean {
    if (ssrc != null) {
        m[0].ssrc = ssrc.*;
        m[0].ssrc_valid = 1;
    } else m[0].ssrc_valid = 0;
    return 1;
}

pub export fn gst_rtp_source_meta_append_csrc(m: [*c]Meta, csrc: [*c]const c.guint32, count: c.guint) c.gboolean {
    const n = m[0].csrc_count + count;
    if (n > MAX) return 0;
    for (0..count) |i| m[0].csrc[m[0].csrc_count + i] = csrc[i];
    m[0].csrc_count = n;
    return 1;
}

pub export fn gst_rtp_source_meta_api_get_type() c.GType {
    return api_once.get(struct {
        var tags = [_][*c]const u8{null};
        fn f() c.GType {
            return c.gst_meta_api_type_register("GstRTPSourceMetaAPI", @ptrCast(&tags));
        }
    }.f);
}

fn init(meta: [*c]c.GstMeta, _: c.gpointer, _: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const m: [*c]Meta = @ptrCast(@alignCast(meta));
    m[0].ssrc_valid = 0;
    m[0].csrc_count = 0;
    return 1;
}

pub export fn gst_rtp_source_meta_get_info() [*c]const c.GstMetaInfo {
    info_lock.lock();
    defer info_lock.unlock();
    if (info == null) info = c.gst_meta_register(gst_rtp_source_meta_api_get_type(), "GstRTPSourceMeta", @sizeOf(Meta), init, null, transform);
    return info;
}
