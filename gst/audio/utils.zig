const c = @import("../c.zig").c;
const check = @import("check.zig");

fn proxyCaps(templ: [*c]c.GstCaps, caps: [*c]c.GstCaps) [*c]c.GstCaps {
    var result = c.gst_caps_new_empty();
    const tn = c.gst_caps_get_size(templ);
    const cn = c.gst_caps_get_size(caps);
    var i: c.guint = 0;
    while (i < tn) : (i += 1) {
        const name = c.gst_structure_get_name_id_str(c.gst_caps_get_structure(templ, i));
        const features = c.gst_caps_get_features(templ, i);
        var j: c.guint = 0;
        while (j < cn) : (j += 1) {
            const cs = c.gst_caps_get_structure(caps, j);
            const s = c.gst_structure_new_id_str_empty(name);
            for ([_][*c]const u8{ "rate", "channels", "channels-mask" }) |field| {
                const v = c.gst_structure_get_value(cs, field);
                if (v != null) c.gst_structure_set_value(s, field, v);
            }
            result = c.gst_caps_merge_structure_full(result, s, c.gst_caps_features_copy(features));
        }
    }
    return result;
}

pub fn proxyGetcaps(sinkpad: ?*c.GstPad, srcpad: ?*c.GstPad, initial: [*c]c.GstCaps, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const templ = if (initial != null) c.gst_caps_ref(initial) else c.gst_pad_get_pad_template_caps(sinkpad);
    const src_templ = c.gst_pad_get_pad_template_caps(srcpad);
    var peer: [*c]c.GstCaps = undefined;
    if (filter != null and c.gst_caps_is_any(filter) == 0) {
        const pf = proxyCaps(src_templ, filter);
        peer = c.gst_pad_peer_query_caps(srcpad, pf);
        c.gst_caps_unref(pf);
    } else peer = c.gst_pad_peer_query_caps(srcpad, null);
    var allowed = c.gst_caps_intersect_full(peer, src_templ, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(src_templ);
    c.gst_caps_unref(peer);
    var out: [*c]c.GstCaps = undefined;
    if (allowed == null or c.gst_caps_is_any(allowed) != 0) {
        out = templ;
    } else if (c.gst_caps_is_empty(allowed) != 0) {
        out = c.gst_caps_ref(allowed);
    } else {
        const fc = proxyCaps(templ, allowed);
        out = c.gst_caps_intersect_full(fc, templ, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(fc);
        c.gst_caps_unref(templ);
        if (filter != null) {
            const f2 = c.gst_caps_intersect_full(out, filter, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(out);
            out = f2;
        }
    }
    _ = c.gst_caps_replace(&allowed, null);
    return out;
}

pub fn encodedConvert(info: [*c]const c.GstAudioInfo, bytes_in: i64, samples: i64, src_fmt: c.GstFormat, src_val: i64, dest_fmt: [*c]c.GstFormat, dest_val: [*c]i64) bool {
    if (!check.that(dest_fmt != null, "__gst_audio_encoded_audio_convert", "dest_format != NULL")) return false;
    if (!check.that(dest_val != null, "__gst_audio_encoded_audio_convert", "dest_value != NULL")) return false;
    if (src_fmt == dest_fmt.* or src_val == 0 or src_val == -1) {
        dest_val.* = src_val;
        return true;
    }
    if (samples == 0 or bytes_in == 0 or info.*.rate == 0) return false;
    const bytes: u64 = @bitCast(bytes_in *% info.*.rate);
    const sec: u64 = c.GST_SECOND;
    const smp: u64 = @bitCast(samples);
    const sv: u64 = @bitCast(src_val);
    switch (src_fmt) {
        c.GST_FORMAT_BYTES => if (dest_fmt.* == c.GST_FORMAT_TIME) {
            dest_val.* = @bitCast(c.gst_util_uint64_scale(sv, sec *% smp, bytes));
            return true;
        },
        c.GST_FORMAT_TIME => if (dest_fmt.* == c.GST_FORMAT_BYTES) {
            dest_val.* = @bitCast(c.gst_util_uint64_scale(sv, bytes, smp *% sec));
            return true;
        },
        else => {},
    }
    return false;
}
