const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const CAPS = "audio/x-dsd, format = (string) " ++ c.GST_DSD_FORMATS_ALL ++ ", rate = " ++ c.GST_AUDIO_RATE_RANGE ++ ", layout = (string) { interleaved, non-interleaved }, reversed-bytes = (gboolean) { false, true }, channels = " ++ c.GST_AUDIO_CHANNELS_RANGE;

const Self = extern struct {
    parent: c.GstBaseTransform,
    in_info: c.GstDsdInfo,
    out_info: c.GstDsdInfo,
    adapter: ?*c.GstAdapter,
};

const Class = extern struct {
    parent: c.GstBaseTransformClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent: ?*c.GstBaseTransformClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn planeMeta(b: [*c]c.GstBuffer) ?*c.GstDsdPlaneOffsetMeta {
    return @ptrCast(@alignCast(c.gst_buffer_get_meta(b, c.gst_dsd_plane_offset_meta_api_get_type())));
}

fn setCaps(bt: [*c]c.GstBaseTransform, in: [*c]c.GstCaps, out: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const s = me(bt);
    if (c.gst_dsd_info_from_caps(&s.in_info, in) == 0) return 0;
    if (c.gst_dsd_info_from_caps(&s.out_info, out) == 0) return 0;
    c.gst_base_transform_set_passthrough(bt, c.gst_dsd_info_is_equal(&s.in_info, &s.out_info));
    return 1;
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const ret = parent.?.prepare_output_buffer.?(bt, in, out);
    if (ret != c.GST_FLOW_OK) return ret;
    if (s.out_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
        if (out.* == null) c.g_assertion_message_expr(null, "../gst/dsd/gstdsdconvert.c", 165, "gst_dsd_convert_prepare_output_buffer", "*outbuf != NULL");
        _ = c.gst_buffer_add_dsd_plane_offset_meta(out.*, s.out_info.channels, 0, null);
    }
    return c.GST_FLOW_OK;
}

fn stripFormat(_: ?*c.GstCapsFeatures, st: ?*c.GstStructure, _: c.gpointer) callconv(.c) c.gboolean {
    c.gst_structure_remove_fields(st, "format", "layout", "reversed-bytes", @as(?*anyopaque, null));
    return 1;
}

fn transformCaps(_: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    var tmp = c.gst_caps_copy(caps);
    _ = c.gst_caps_map_in_place(tmp, stripFormat, null);
    const tc = c.gst_static_pad_template_get_caps(&sink_t);
    const res = c.gst_caps_intersect_full(tmp, tc, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(tmp);
    c.gst_caps_unref(tc);
    tmp = res;
    if (filter != null) {
        const f = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(tmp);
        tmp = f;
    }
    return tmp;
}

fn transformSize(_: [*c]c.GstBaseTransform, _: c.GstPadDirection, caps: [*c]c.GstCaps, size: usize, other: [*c]c.GstCaps, other_size: [*c]usize) callconv(.c) c.gboolean {
    const fname = "gst_dsd_convert_transform_size";
    if (!cm.that(caps != null, fname, "caps != NULL")) return 0;
    if (!cm.that(other != null, fname, "othercaps != NULL")) return 0;
    if (!cm.that(other_size != null, fname, "othersize != NULL")) return 0;
    var info: c.GstDsdInfo = undefined;
    var oinfo: c.GstDsdInfo = undefined;
    if (c.gst_dsd_info_from_caps(&info, caps) == 0) return 0;
    if (c.gst_dsd_info_from_caps(&oinfo, other) == 0) return 0;
    const w = @max(c.gst_dsd_format_get_width(info.format), c.gst_dsd_format_get_width(oinfo.format));
    other_size.* = (size / w) * w;
    return 1;
}

fn transform(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const fname = "gst_dsd_convert_transform";
    if (!cm.that(in != null, fname, "inbuf != NULL")) return c.GST_FLOW_ERROR;
    if (!cm.that(out != null, fname, "outbuf != NULL")) return c.GST_FLOW_ERROR;
    const n_ch = s.in_info.channels;
    var in_offs: [*c]const usize = null;
    var out_offs: [*c]const usize = null;
    var n_bytes: usize = 0;
    if (s.in_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) {
        const m = planeMeta(in) orelse return c.GST_FLOW_ERROR;
        in_offs = m.offsets;
        n_bytes = m.num_bytes_per_channel * @as(usize, @intCast(n_ch));
    }
    var om: ?*c.GstDsdPlaneOffsetMeta = null;
    if (s.out_info.layout == c.GST_AUDIO_LAYOUT_NON_INTERLEAVED) om = planeMeta(out) orelse return c.GST_FLOW_ERROR;
    var imap: c.GstMapInfo = undefined;
    var omap: c.GstMapInfo = undefined;
    if (c.gst_buffer_map(in, &imap, c.GST_MAP_READ) == 0) return c.GST_FLOW_ERROR;
    defer c.gst_buffer_unmap(in, &imap);
    if (c.gst_buffer_map(out, &omap, c.GST_MAP_WRITE) == 0) return c.GST_FLOW_ERROR;
    defer c.gst_buffer_unmap(out, &omap);
    if (s.in_info.layout == c.GST_AUDIO_LAYOUT_INTERLEAVED) n_bytes = imap.size;
    const reverse = s.in_info.reversed_bytes != s.out_info.reversed_bytes;
    if (om) |m| {
        m.num_bytes_per_channel = n_bytes / @as(usize, @intCast(n_ch));
        var i: usize = 0;
        while (i < @as(usize, @intCast(n_ch))) : (i += 1) m.offsets[i] = m.num_bytes_per_channel * i;
        out_offs = m.offsets;
    }
    c.gst_dsd_convert(imap.data, omap.data, s.in_info.format, s.out_info.format, s.in_info.layout, s.out_info.layout, in_offs, out_offs, n_bytes, n_ch, @intFromBool(reverse));
    return c.GST_FLOW_OK;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("dsdconvert", 0, "DSD grouping format converter");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.set_caps = setCaps;
    tc.prepare_output_buffer = prepareOutput;
    tc.transform_caps = transformCaps;
    tc.transform_size = transformSize;
    tc.transform = transform;
    c.gst_element_class_set_static_metadata(ec, "DSD converter", "Filter/Converter/Audio", "Convert between different DSD grouping formats", "Carlos Rafael Giani <crg7475@mailbox.org>");
}

fn init(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_base_transform_get_type(), "GstDsdConvert", Class, Self, classInit, init);
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return c.gst_element_register(p, "dsdconvert", c.GST_RANK_SECONDARY, getType()) != 0;
}
