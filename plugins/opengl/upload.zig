const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstgluploadelement.c";

const Self = extern struct {
    parent: c.GstGLBaseFilter,
    upload: ?*c.GstGLUpload,
};

const Class = extern struct {
    parent: c.GstGLBaseFilterClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw(ANY)");
var once: cm.Once = .{};
var parent: *c.GstBaseTransformClass = undefined;
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn clear(s: *Self) void {
    cm.lock(s);
    const ul = s.upload;
    s.upload = null;
    cm.unlock(s);
    if (ul != null) c.gst_object_unref(ul);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    clear(me(o));
    parent_obj.finalize.?(o);
}

fn stop(bt: [*c]c.GstBaseTransform) callconv(.c) c.gboolean {
    clear(me(bt));
    return parent.stop.?(bt);
}

fn transformCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, filter: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    const s = me(bt);
    const bf = el.base(bt);
    if (bf.display != null and c.gst_gl_base_filter_find_gl_context(bf) == 0) return null;
    const ctx = c.gst_gl_base_filter_get_gl_context(bf);
    defer if (ctx != null) c.gst_object_unref(ctx);
    cm.lock(s);
    var ul = s.upload;
    if (ul == null) {
        cm.unlock(s);
        const fresh = c.gst_gl_upload_new(ctx);
        cm.lock(s);
        if (s.upload != null) {
            c.gst_object_unref(fresh);
            ul = s.upload;
        } else {
            s.upload = fresh;
            ul = fresh;
        }
    }
    _ = c.gst_object_ref(ul);
    cm.unlock(s);
    defer c.gst_object_unref(ul);
    return c.gst_gl_upload_transform_caps(ul, ctx, dir, caps, filter);
}

fn proposeAllocation(bt: [*c]c.GstBaseTransform, decide: [*c]c.GstQuery, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bt);
    cm.lock(s);
    if (s.upload == null) {
        cm.unlock(s);
        return 0;
    }
    const ul: ?*c.GstGLUpload = @ptrCast(@alignCast(c.gst_object_ref(s.upload)));
    cm.unlock(s);
    defer c.gst_object_unref(ul);
    const ctx = c.gst_gl_base_filter_get_gl_context(el.base(bt));
    if (ctx == null) return 0;
    defer c.gst_object_unref(ctx);
    c.gst_gl_upload_set_context(ul, ctx);
    const ret = parent.propose_allocation.?(bt, decide, q);
    c.gst_gl_upload_propose_allocation(ul, decide, q);
    return ret;
}

fn decideAllocation(bt: [*c]c.GstBaseTransform, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(bt);
    const ctx = el.base(bt).context;
    if (s.upload != null and ctx != null) c.gst_gl_upload_set_context(s.upload, ctx);
    return parent.decide_allocation.?(bt, q);
}

fn setCaps(bt: [*c]c.GstBaseTransform, in: [*c]c.GstCaps, out: [*c]c.GstCaps) callconv(.c) c.gboolean {
    return c.gst_gl_upload_set_caps(me(bt).upload, in, out);
}

fn prepareOutput(bt: [*c]c.GstBaseTransform, in: [*c]c.GstBuffer, out: [*c][*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(bt);
    const k: *c.GstBaseTransformClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(bt)).g_class));
    if (c.gst_base_transform_is_passthrough(bt) != 0) {
        out.* = in;
        return c.GST_FLOW_OK;
    }
    if (s.upload == null) return c.GST_FLOW_NOT_NEGOTIATED;
    while (true) {
        const r = c.gst_gl_upload_perform_with_buffer(s.upload, in, out);
        if (r == c.GST_GL_UPLOAD_RECONFIGURE) {
            const sink = bt[0].sinkpad;
            const caps = c.gst_pad_get_current_caps(sink);
            _ = c.gst_pad_send_event(sink, c.gst_event_new_caps(caps));
            c.gst_caps_unref(caps);
            if (c.gst_pad_needs_reconfigure(bt[0].srcpad) == 0) continue;
            return c.GST_FLOW_OK;
        }
        if (r != c.GST_GL_UPLOAD_DONE or out.* == null) {
            cm.elementError(bt, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to upload buffer"), null, FILE, "gst_gl_upload_element_prepare_output_buffer", 317);
            if (out.* != null) c.gst_buffer_unref(out.*);
            return c.GST_FLOW_ERROR;
        }
        break;
    }
    if (in == out.*) {
        c.gst_buffer_unref(out.*);
    } else _ = k.copy_metadata.?(bt, in, out.*);
    return c.GST_FLOW_OK;
}

fn transformMeta(bt: [*c]c.GstBaseTransform, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    if (!el.videoTagsOnly(meta, true)) return parent.transform_meta.?(bt, out, meta, in);
    return 1;
}

fn fixateCaps(bt: [*c]c.GstBaseTransform, dir: c.GstPadDirection, caps: [*c]c.GstCaps, other: [*c]c.GstCaps) callconv(.c) [*c]c.GstCaps {
    return c.gst_gl_upload_fixate_caps(me(bt).upload, dir, caps, other);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const ret = parent_el.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) clear(me(e));
    return ret;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = el.parentOf(c.GstBaseTransformClass, k);
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const bt = el.baseTransformClass(k);
    bt.transform_caps = transformCaps;
    bt.set_caps = setCaps;
    bt.filter_meta = el.keepMeta;
    bt.propose_allocation = proposeAllocation;
    bt.decide_allocation = decideAllocation;
    bt.get_unit_size = el.unitSize;
    bt.prepare_output_buffer = prepareOutput;
    bt.transform = el.noTransform;
    bt.stop = stop;
    bt.fixate_caps = fixateCaps;
    bt.transform_meta = transformMeta;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const caps = c.gst_gl_upload_get_input_template_caps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(ec, "OpenGL uploader", "Filter/Video", "Uploads data into OpenGL", "Matthew Waters <matthew@centricular.com>");
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    c.gst_base_transform_set_prefer_passthrough(@ptrCast(@alignCast(inst)), 1);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_gl_base_filter_get_type(), "GstGLUploadElement", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("gluploadelement", 0, "glupload Element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glupload", c.GST_RANK_NONE, getType());
}
