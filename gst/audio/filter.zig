const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const info = @import("info.zig");
const clip = @import("clip.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Filter = c.GstAudioFilter;
const Class = c.GstAudioFilterClass;
const BT = c.GstBaseTransform;
const BTClass = c.GstBaseTransformClass;

var once: gtype.Once = .{};
var parent: ?*BTClass = null;
var audio_tag: c.GQuark = 0;

fn of(p: anytype) [*c]Filter {
    return @ptrCast(@alignCast(p));
}

fn transformMeta(t: [*c]BT, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const api = meta.*.info.*.api;
    const tags = c.gst_meta_api_type_get_tags(api);
    if (tags == null or (c.g_strv_length(@constCast(@ptrCast(tags))) == 1 and c.gst_meta_api_type_has_tag(api, audio_tag) != 0)) return 1;
    return parent.?.transform_meta.?(t, out, meta, in);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = @as(*c.GstElementClass, @ptrCast(parent)).change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY or t == c.GST_STATE_CHANGE_READY_TO_NULL) info.gst_audio_info_init(&of(e).*.info);
    return ret;
}

fn setCaps(b: [*c]BT, incaps: [*c]c.GstCaps, _: [*c]c.GstCaps) callconv(.c) c.gboolean {
    const f = of(b);
    var ai: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&ai, incaps) == 0) return 0;
    const k = gtype.classPeek(Class, f);
    const ok = if (k.setup) |setup| setup(f, &ai) else 1;
    if (ok != 0) f.*.info = ai;
    return ok;
}

fn submitInput(b: [*c]BT, discont: c.gboolean, input: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const f = of(b);
    var buf = input;
    if (b.*.segment.format == c.GST_FORMAT_TIME) {
        if (f.*.info.finfo == null or f.*.info.rate <= 0 or f.*.info.channels <= 0 or f.*.info.bpf <= 0) return c.GST_FLOW_NOT_NEGOTIATED;
        buf = clip.gst_audio_buffer_clip(buf, &b.*.segment, f.*.info.rate, f.*.info.bpf);
        if (buf == null) return c.GST_FLOW_OK;
    }
    return parent.?.submit_input_buffer.?(b, discont, buf);
}

fn unitSize(_: [*c]BT, caps: [*c]c.GstCaps, size: [*c]c.gsize) callconv(.c) c.gboolean {
    var ai: c.GstAudioInfo = undefined;
    if (info.gst_audio_info_from_caps(&ai, caps) == 0) return 0;
    size.* = @intCast(ai.bpf);
    return 1;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    const bc: *BTClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    bc.set_caps = setCaps;
    bc.get_unit_size = unitSize;
    bc.transform_meta = transformMeta;
    bc.submit_input_buffer = submitInput;
    audio_tag = c.g_quark_from_static_string("audio");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    info.gst_audio_info_init(&of(inst).*.info);
}

pub export fn gst_audio_filter_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_base_transform_get_type, "GstAudioFilter", Class, Filter, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            _ = c._gst_debug_category_new("audiofilter", 0, "audiofilter");
            return t;
        }
    }.f);
}

pub export fn gst_audio_filter_class_add_pad_templates(k: [*c]Class, allowed: [*c]c.GstCaps) void {
    if (!check.that(k != null and c.g_type_check_class_is_a(@ptrCast(k), gst_audio_filter_get_type()) != 0, "gst_audio_filter_class_add_pad_templates", "GST_IS_AUDIO_FILTER_CLASS (klass)")) return;
    if (!check.that(allowed != null and allowed.*.mini_object.type == c.gst_caps_get_type(), "gst_audio_filter_class_add_pad_templates", "GST_IS_CAPS (allowed_caps)")) return;
    const ec: [*c]c.GstElementClass = @ptrCast(k);
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, allowed));
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, allowed));
}
