const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const flags = @import("playflags.zig");

pub const RAW_CAPS = "video/x-raw(ANY); audio/x-raw(ANY); text/x-raw(ANY); subpicture/x-dvd; subpicture/x-dvb; subpicture/x-xsub; subpicture/x-pgs; closedcaption/x-cea-608; closedcaption/x-cea-708; application/x-onvif-metadata; meta/x-klv; meta/x-id3; meta/x-st-2038; ";

var raw_caps = c.GstStaticCaps{ .caps = null, .string = RAW_CAPS, ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var raw_audio = c.GstStaticCaps{ .caps = null, .string = "audio/x-raw(ANY)", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };
var raw_video = c.GstStaticCaps{ .caps = null, .string = "video/x-raw(ANY)", ._gst_reserved = std.mem.zeroes([4]c.gpointer) };

pub fn rawCaps() [*c]c.GstCaps {
    return c.gst_static_caps_get(&raw_caps);
}

pub fn streamInList(streams: [*c]c.GList, stream: ?*c.GstStream) bool {
    const id = c.gst_stream_get_stream_id(stream);
    const kind = c.gst_stream_get_stream_type(stream);
    var l = streams;
    while (l != null) : (l = l.*.next) {
        const cand: ?*c.GstStream = @ptrCast(@alignCast(l.*.data));
        if (cand == stream) return true;
        if (c.gst_stream_get_stream_type(cand) != kind) continue;
        if (c.g_strcmp0(id, c.gst_stream_get_stream_id(cand)) == 0) return true;
    }
    return false;
}

pub fn compareFactories(a: c.gconstpointer, b: c.gconstpointer) callconv(.c) c.gint {
    const fa: ?*c.GstElementFactory = @ptrCast(@alignCast(@constCast(a)));
    const fb: ?*c.GstElementFactory = @ptrCast(@alignCast(@constCast(b)));
    const pa = c.gst_element_factory_list_is_type(fa, c.GST_ELEMENT_FACTORY_TYPE_PARSER) != 0;
    const pb = c.gst_element_factory_list_is_type(fb, c.GST_ELEMENT_FACTORY_TYPE_PARSER) != 0;
    if (pa and !pb) return -1;
    if (!pa and pb) return 1;
    return c.gst_plugin_feature_rank_compare_func(a, b);
}

fn templateCaps(f: ?*c.GstElementFactory, dir: c.GstPadDirection) [*c]c.GstCaps {
    var last: ?*c.GstStaticPadTemplate = null;
    var l: ?*const c.GList = c.gst_element_factory_get_static_pad_templates(f);
    while (l) |n| : (l = n.next) {
        last = @ptrCast(@alignCast(n.data));
        if (last.?.direction == dir) break;
    }
    const t = last orelse return null;
    return c.gst_static_caps_get(&t.static_caps);
}

pub fn commonCapsFeatures(f1: ?*c.GstElementFactory, f2: ?*c.GstElementFactory, fl: c.guint, audio: bool) c.guint {
    const raw = c.gst_static_caps_get(if (audio) &raw_audio else &raw_video);
    defer c.gst_caps_unref(raw);
    const raw_s = c.gst_caps_get_structure(raw, 0);
    const native = (fl & (if (audio) flags.NATIVE_AUDIO else flags.NATIVE_VIDEO)) != 0;
    const c1 = templateCaps(f1, c.GST_PAD_SRC);
    const c2 = templateCaps(f2, c.GST_PAD_SINK);
    if (c1 == null or c2 == null) {
        if (c1 != null) c.gst_caps_unref(c1) else if (c2 != null) c.gst_caps_unref(c2);
        return 0;
    }
    defer c.gst_caps_unref(c1);
    defer c.gst_caps_unref(c2);
    var seen: [*c]c.GList = null;
    defer c.g_list_free(seen);
    var n: c.guint = 0;
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(c1)) : (i += 1) {
        const ft1 = c.gst_caps_get_features(c1, i);
        if (c.gst_caps_features_is_any(ft1) != 0) continue;
        const s1 = c.gst_caps_get_structure(c1, i);
        var j: c.guint = 0;
        while (j < c.gst_caps_get_size(c2)) : (j += 1) {
            const ft2 = c.gst_caps_get_features(c2, j);
            if (c.gst_caps_features_is_any(ft2) != 0) continue;
            const s2 = c.gst_caps_get_structure(c2, j);
            if (c.gst_caps_features_is_equal(ft1, ft2) == 0) continue;
            const meets = c.gst_structure_can_intersect(s1, s2) != 0 or (!native and c.gst_caps_features_is_equal(ft1, c.GST_CAPS_FEATURES_MEMORY_SYSTEM_MEMORY) != 0 and c.gst_structure_can_intersect(raw_s, s1) != 0 and c.gst_structure_can_intersect(raw_s, s2) != 0);
            if (!meets) continue;
            var dup = false;
            var l = seen;
            while (l != null) : (l = l.*.next) {
                if (c.gst_caps_features_is_equal(@ptrCast(@alignCast(l.*.data)), ft2) != 0) dup = true;
            }
            if (dup) continue;
            seen = c.g_list_prepend(seen, ft2);
            n += 1;
        }
    }
    return n;
}
