const c = @import("../c.zig").c;
const check = @import("check.zig");

const Caps = c.GstCaps;

fn proxyCaps(templ: [*c]Caps, caps: [*c]Caps) [*c]Caps {
    var result = c.gst_caps_new_empty();
    const fields = [_][*:0]const u8{ "width", "height", "framerate", "pixel-aspect-ratio", "colorimetry", "chroma-site" };
    for (0..c.gst_caps_get_size(templ)) |i| {
        const name = c.gst_structure_get_name_id_str(c.gst_caps_get_structure(templ, @intCast(i)));
        const features = c.gst_caps_get_features(templ, @intCast(i));
        for (0..c.gst_caps_get_size(caps)) |j| {
            const cs = c.gst_caps_get_structure(caps, @intCast(j));
            const tmp = c.gst_caps_new_empty();
            const s = c.gst_structure_new_id_str_empty(name);
            for (fields) |f| {
                const v = c.gst_structure_get_value(cs, f);
                if (v != null) c.gst_structure_set_value(s, f, v);
            }
            c.gst_caps_append_structure_full(tmp, s, c.gst_caps_features_copy(features));
            result = c.gst_caps_merge(result, tmp);
        }
    }
    return result;
}

pub fn proxyGetcaps(sinkpad: ?*c.GstPad, srcpad: ?*c.GstPad, initial: [*c]Caps, filter: [*c]Caps) [*c]Caps {
    const templ = if (initial != null) c.gst_caps_ref(initial) else c.gst_pad_get_pad_template_caps(sinkpad);
    const src_templ = c.gst_pad_get_pad_template_caps(srcpad);
    var peer: [*c]Caps = undefined;
    if (filter != null and c.gst_caps_is_any(filter) == 0) {
        const pf = proxyCaps(src_templ, filter);
        peer = c.gst_pad_peer_query_caps(srcpad, pf);
        c.gst_caps_unref(pf);
    } else peer = c.gst_pad_peer_query_caps(srcpad, null);
    var allowed = c.gst_caps_intersect_full(peer, src_templ, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(src_templ);
    c.gst_caps_unref(peer);
    var fcaps: [*c]Caps = undefined;
    if (allowed == null or c.gst_caps_is_any(allowed) != 0) {
        fcaps = templ;
    } else if (c.gst_caps_is_empty(allowed) != 0) {
        fcaps = c.gst_caps_ref(allowed);
    } else {
        const fc = proxyCaps(templ, allowed);
        fcaps = c.gst_caps_intersect(fc, templ);
        c.gst_caps_unref(fc);
        c.gst_caps_unref(templ);
        if (filter != null) {
            const f2 = c.gst_caps_intersect(fcaps, filter);
            c.gst_caps_unref(fcaps);
            fcaps = f2;
        }
    }
    _ = c.gst_caps_replace(&allowed, null);
    return fcaps;
}

pub fn rawvideoConvert(state: [*c]c.GstVideoCodecState, src_format: c.GstFormat, src_value: i64, dest_format: [*c]c.GstFormat, dest_value: [*c]i64) bool {
    if (!check.that(dest_format != null, "__gst_video_rawvideo_convert", "dest_format != NULL")) return false;
    if (!check.that(dest_value != null, "__gst_video_rawvideo_convert", "dest_value != NULL")) return false;
    if (src_format == dest_format[0] or src_value == 0 or src_value == -1) {
        dest_value[0] = src_value;
        return true;
    }
    const vidsize: c.guint = @truncate(state[0].info.size);
    const fps_n: c.guint = @bitCast(state[0].info.fps_n);
    const fps_d: c.guint = @bitCast(state[0].info.fps_d);
    const sv: u64 = @bitCast(src_value);
    const SEC: u64 = c.GST_SECOND;
    const df = dest_format[0];
    var r: u64 = 0;
    if (src_format == c.GST_FORMAT_BYTES and df == c.GST_FORMAT_DEFAULT and vidsize != 0) {
        r = c.gst_util_uint64_scale_int(sv, 1, @bitCast(vidsize));
    } else if (src_format == c.GST_FORMAT_DEFAULT and df == c.GST_FORMAT_BYTES and vidsize != 0) {
        r = sv *% vidsize;
    } else if (src_format == c.GST_FORMAT_DEFAULT and df == c.GST_FORMAT_TIME and fps_n != 0) {
        r = c.gst_util_uint64_scale(sv, SEC *% fps_d, fps_n);
    } else if (src_format == c.GST_FORMAT_TIME and df == c.GST_FORMAT_DEFAULT and fps_d != 0) {
        r = c.gst_util_uint64_scale(sv, fps_n, SEC *% fps_d);
    } else if (src_format == c.GST_FORMAT_TIME and df == c.GST_FORMAT_BYTES and fps_d != 0 and vidsize != 0) {
        r = c.gst_util_uint64_scale(sv, @as(u64, fps_n) *% vidsize, SEC *% fps_d);
    } else if (src_format == c.GST_FORMAT_BYTES and df == c.GST_FORMAT_TIME and fps_n != 0 and vidsize != 0) {
        r = c.gst_util_uint64_scale(sv, SEC *% fps_d, @as(u64, fps_n) *% vidsize);
    } else return false;
    dest_value[0] = @bitCast(r);
    return true;
}

pub fn encodedConvert(bytes: i64, time: i64, src_format: c.GstFormat, src_value: i64, dest_format: [*c]c.GstFormat, dest_value: [*c]i64) bool {
    if (!check.that(dest_format != null, "__gst_video_encoded_video_convert", "dest_format != NULL")) return false;
    if (!check.that(dest_value != null, "__gst_video_encoded_video_convert", "dest_value != NULL")) return false;
    if (src_format == dest_format[0] or src_value == 0 or src_value == -1) {
        dest_value[0] = src_value;
        return true;
    }
    if (bytes <= 0 or time <= 0) return false;
    const sv: u64 = @bitCast(src_value);
    if (src_format == c.GST_FORMAT_BYTES and dest_format[0] == c.GST_FORMAT_TIME) {
        dest_value[0] = @bitCast(c.gst_util_uint64_scale(sv, @bitCast(time), @bitCast(bytes)));
        return true;
    }
    if (src_format == c.GST_FORMAT_TIME and dest_format[0] == c.GST_FORMAT_BYTES) {
        dest_value[0] = @bitCast(c.gst_util_uint64_scale(sv, @bitCast(bytes), @bitCast(time)));
        return true;
    }
    return false;
}

pub fn padSetCaps(pad: ?*c.GstPad, caps: [*c]Caps) bool {
    const is_pad = pad != null and c.g_type_check_instance_is_a(@ptrCast(@alignCast(pad)), c.gst_pad_get_type()) != 0;
    if (!check.that(is_pad, "gst_pad_set_caps", "GST_IS_PAD (pad)")) return false;
    if (!check.that(caps != null and c.gst_caps_is_fixed(caps) != 0, "gst_pad_set_caps", "caps != NULL && gst_caps_is_fixed (caps)")) return false;
    const ev = c.gst_event_new_caps(caps);
    if (c.gst_pad_get_direction(pad) == c.GST_PAD_SRC) return c.gst_pad_push_event(pad, ev) != 0;
    return c.gst_pad_send_event(pad, ev) != 0;
}
