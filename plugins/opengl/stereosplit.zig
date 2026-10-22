const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const FILE = "../ext/gl/gstglstereosplit.c";
const APIS = c.GST_GL_API_GLES2 | c.GST_GL_API_OPENGL | c.GST_GL_API_OPENGL3;
const CAPS = el.capsWithFeatures(c.GST_CAPS_FEATURE_MEMORY_GL_MEMORY, "RGBA");

const Self = extern struct {
    parent: c.GstElement,
    sink_pad: ?*c.GstPad,
    left_pad: ?*c.GstPad,
    right_pad: ?*c.GstPad,
    display: ?*c.GstGLDisplay,
    context: ?*c.GstGLContext,
    other_context: ?*c.GstGLContext,
    viewconvert: ?*c.GstGLViewConvert,
    context_lock: c.GRecMutex,
};

const Class = extern struct {
    parent: c.GstElementClass,
};

var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, CAPS);
var left_t = cm.staticTemplate("left", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var right_t = cm.staticTemplate("right", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, CAPS);
var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn lock(s: *Self) void {
    c.g_rec_mutex_lock(&s.context_lock);
}

fn unlock(s: *Self) void {
    c.g_rec_mutex_unlock(&s.context_lock);
}

fn clear(p: anytype) void {
    if (p.* != null) c.gst_object_unref(p.*);
    p.* = null;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    clear(&s.viewconvert);
    c.g_rec_mutex_clear(&s.context_lock);
    parent_obj.finalize.?(o);
}

fn setContext(e: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const s = me(e);
    lock(s);
    var old: ?*c.GstGLDisplay = if (s.display != null) @ptrCast(@alignCast(c.gst_object_ref(s.display))) else null;
    _ = c.gst_gl_handle_set_context(e, ctx, @ptrCast(&s.display), @ptrCast(&s.other_context));
    if (s.display != null) c.gst_gl_display_filter_gl_api(s.display, APIS);
    var new: ?*c.GstGLDisplay = if (s.display != null) @ptrCast(@alignCast(c.gst_object_ref(s.display))) else null;
    if (old != null and new != null and old != new) {
        clear(&s.context);
        c.gst_gl_view_convert_set_context(s.viewconvert, null);
        if (ensureUnlocked(s)) c.gst_gl_view_convert_set_context(s.viewconvert, s.context);
    }
    clear(&old);
    clear(&new);
    unlock(s);
    parent_el.set_context.?(e, ctx);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) {
        lock(s);
        if (c.gst_gl_ensure_element_data(e, @ptrCast(&s.display), @ptrCast(&s.other_context)) == 0) {
            unlock(s);
            return c.GST_STATE_CHANGE_FAILURE;
        }
        c.gst_gl_display_filter_gl_api(s.display, APIS);
        unlock(s);
    }
    const r = parent_el.change_state.?(e, t);
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        lock(s);
        clear(&s.other_context);
        clear(&s.display);
        unlock(s);
    } else if (t == c.GST_STATE_CHANGE_PAUSED_TO_READY) {
        clear(&s.context);
        clear(&s.display);
    }
    return r;
}

fn stripViews(caps: [*c]c.GstCaps, keep: c.guint) [*c]c.GstCaps {
    const out: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(caps)));
    for (0..c.gst_caps_get_size(out)) |i| {
        const st = c.gst_caps_get_structure(out, @intCast(i));
        c.gst_structure_remove_field(st, "multiview-mode");
        var flags: c.guint = 0;
        var mask: c.guint = 0;
        if (c.gst_structure_get_flagset(st, "multiview-flags", &flags, &mask) != 0) c.gst_structure_set(st, "multiview-flags", c.gst_video_multiview_flagset_get_type(), flags & keep, keep, @as(?*anyopaque, null));
    }
    return out;
}

fn srcCaps(pad: ?*c.GstPad, mode: c.GstVideoMultiviewMode) [*c]c.GstCaps {
    const templ: [*c]c.GstCaps = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(c.gst_pad_get_pad_template_caps(pad))));
    var item = std.mem.zeroes(c.GValue);
    var list = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&item, c.G_TYPE_STRING);
    _ = c.g_value_init(&list, c.gst_value_list_get_type());
    c.g_value_set_static_string(&item, c.gst_video_multiview_mode_to_caps_string(mode));
    c.gst_value_list_append_value(&list, &item);
    c.g_value_set_static_string(&item, c.gst_video_multiview_mode_to_caps_string(c.GST_VIDEO_MULTIVIEW_MODE_MONO));
    c.gst_value_list_append_value(&list, &item);
    c.gst_caps_set_value(templ, "multiview-mode", &list);
    c.g_value_unset(&list);
    c.g_value_unset(&item);
    const peer = c.gst_pad_peer_query_caps(pad, null);
    if (peer == null) {
        c.gst_caps_unref(templ);
        return null;
    }
    const out = c.gst_caps_intersect_full(peer, templ, c.GST_CAPS_INTERSECT_FIRST);
    c.gst_caps_unref(peer);
    c.gst_caps_unref(templ);
    return out;
}

fn intersectInto(a: [*c]c.GstCaps, b: [*c]c.GstCaps) [*c]c.GstCaps {
    const r = c.gst_caps_intersect(a, b);
    c.gst_caps_unref(a);
    c.gst_caps_unref(b);
    return r;
}

fn setOutputCaps(s: *Self, sinkcaps: [*c]c.GstCaps) bool {
    var left: [*c]c.GstCaps = null;
    var right: [*c]c.GstCaps = null;
    var trid: [*c]c.GstCaps = null;
    defer {
        if (left != null) c.gst_caps_unref(left);
        if (right != null) c.gst_caps_unref(right);
        if (trid != null) c.gst_caps_unref(trid);
    }
    lock(s);
    const ok = ensureUnlocked(s);
    unlock(s);
    if (!ok) return false;
    left = srcCaps(s.left_pad, c.GST_VIDEO_MULTIVIEW_MODE_LEFT);
    if (left == null) return false;
    right = srcCaps(s.right_pad, c.GST_VIDEO_MULTIVIEW_MODE_RIGHT);
    if (right == null) return false;
    trid = c.gst_gl_view_convert_transform_caps(s.viewconvert, c.GST_PAD_SINK, sinkcaps, null);
    if (trid == null or c.gst_caps_is_empty(trid) != 0) return false;
    trid = intersectInto(trid, stripViews(c.gst_caps_ref(left), c.GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLIPPED | c.GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLOPPED));
    trid = intersectInto(trid, stripViews(c.gst_caps_ref(right), c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLIPPED | c.GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLOPPED));
    if (c.gst_caps_is_empty(trid) != 0) return false;
    var tmp = c.gst_caps_intersect(trid, left);
    c.gst_caps_unref(left);
    left = c.gst_caps_fixate(tmp);
    if (c.gst_pad_push_event(s.left_pad, c.gst_event_new_caps(left)) == 0) return false;
    tmp = c.gst_caps_intersect(trid, right);
    c.gst_caps_unref(right);
    right = c.gst_caps_fixate(tmp);
    if (c.gst_pad_push_event(s.right_pad, c.gst_event_new_caps(right)) == 0) return false;
    _ = doBufferpool(s, left);
    lock(s);
    c.gst_gl_view_convert_set_context(s.viewconvert, s.context);
    trid = @ptrCast(c.gst_mini_object_make_writable(@ptrCast(trid)));
    c.gst_caps_set_simple(trid, "multiview-mode", c.G_TYPE_STRING, "separated", "views", c.G_TYPE_INT, @as(c_int, 2), @as(?*anyopaque, null));
    trid = c.gst_caps_fixate(trid);
    const set = c.gst_gl_view_convert_set_caps(s.viewconvert, sinkcaps, trid) != 0;
    unlock(s);
    return set;
}

fn tryLocal(s: *Self, dir: c.GstPadDirection) bool {
    var ctx = s.context;
    const prev = s.context;
    unlock(s);
    const ret = c.gst_gl_query_local_gl_context(@ptrCast(s), dir, @ptrCast(&ctx)) != 0;
    lock(s);
    if (!ret) return false;
    if (s.context != prev) {
        if (s.context != null and s.context.?.display == s.display) {
            if (ctx != s.context) clear(&ctx);
            return true;
        }
    }
    if (ctx.?.display == s.display) {
        s.context = ctx;
        return true;
    }
    if (ctx != s.context) clear(&ctx);
    return false;
}

fn findLocal(s: *Self) bool {
    if (s.context != null and s.context.?.display == s.display) return true;
    return tryLocal(s, c.GST_PAD_SRC) or tryLocal(s, c.GST_PAD_SINK);
}

fn ensureUnlocked(s: *Self) bool {
    if (c.gst_gl_ensure_element_data(s, @ptrCast(&s.display), @ptrCast(&s.other_context)) == 0) return false;
    c.gst_gl_display_filter_gl_api(s.display, APIS);
    _ = findLocal(s);
    var err: [*c]c.GError = null;
    if (c.gst_gl_display_ensure_context(s.display, s.other_context, @ptrCast(&s.context), &err) == 0) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup(err[0].message), null, FILE, "ensure_context_unlocked", 564);
        c.g_clear_error(&err);
        return false;
    }
    const api = c.gst_gl_context_get_gl_api(s.context);
    if (api & APIS == 0) {
        const a = c.gst_gl_api_to_string(api);
        const b = c.gst_gl_api_to_string(APIS);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, c.g_strdup_printf("GL API's not compatible context: %s supported: %s", a, b), null, FILE, "ensure_context_unlocked", 554);
        c.g_free(b);
        c.g_free(a);
        return false;
    }
    return true;
}

fn doBufferpool(s: *Self, caps: [*c]c.GstCaps) bool {
    const q = c.gst_query_new_allocation(caps, 1);
    if (c.gst_pad_peer_query(s.left_pad, q) == 0) _ = c.gst_pad_peer_query(s.right_pad, q);
    const ok = ensureUnlocked(s);
    c.gst_query_unref(q);
    return ok;
}

fn halfOf(s: *Self, src: [*c]c.GstBuffer, split: [*c]c.GstBuffer, from: c.guint, to: c.guint) [*c]c.GstBuffer {
    _ = s;
    const b = c.gst_buffer_new();
    _ = c.gst_buffer_copy_into(b, src, c.GST_BUFFER_COPY_FLAGS | c.GST_BUFFER_COPY_TIMESTAMPS, 0, std.math.maxInt(usize));
    _ = c.gst_buffer_add_parent_buffer_meta(b, split);
    var i = from;
    while (i < to) : (i += 1) c.gst_buffer_append_memory(b, c.gst_buffer_get_memory(split, i));
    return b;
}

fn chain(_: ?*c.GstPad, parent: ?*c.GstObject, buf: [*c]c.GstBuffer) callconv(.c) c.GstFlowReturn {
    const s = me(parent);
    const n: c.guint = s.viewconvert.?.out_info.finfo[0].n_planes;
    _ = c.gst_buffer_ref(buf);
    defer c.gst_buffer_unref(buf);
    lock(s);
    if (c.gst_gl_view_convert_submit_input_buffer(s.viewconvert, @intFromBool(buf[0].mini_object.flags & c.GST_BUFFER_FLAG_DISCONT != 0), buf) != c.GST_FLOW_OK) {
        unlock(s);
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to 3d convert buffer"), c.g_strdup("Could not get submit input buffer"), FILE, "stereosplit_chain", 639);
        return c.GST_FLOW_ERROR;
    }
    var split: [*c]c.GstBuffer = null;
    const ret = c.gst_gl_view_convert_get_output(s.viewconvert, &split);
    unlock(s);
    if (ret != c.GST_FLOW_OK) {
        cm.elementError(s, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup("Failed to 3d convert buffer"), c.g_strdup("Could not get output buffer"), FILE, "stereosplit_chain", 649);
        return c.GST_FLOW_ERROR;
    }
    if (split == null) return c.GST_FLOW_OK;
    defer c.gst_buffer_unref(split);
    const left = halfOf(s, buf, split, 0, n);
    left[0].mini_object.flags &= ~@as(c.guint, c.GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE);
    const r = c.gst_pad_push(s.left_pad, c.gst_buffer_ref(left));
    c.gst_buffer_unref(left);
    if (r != c.GST_FLOW_OK and r != c.GST_FLOW_NOT_LINKED) return r;
    const right = halfOf(s, buf, split, n, n * 2);
    const r2 = c.gst_pad_push(s.right_pad, c.gst_buffer_ref(right));
    c.gst_buffer_unref(right);
    return r2;
}

fn contextQuery(s: *Self, pad: ?*c.GstPad, parent: ?*c.GstObject, q: [*c]c.GstQuery) c.gboolean {
    lock(s);
    var display: ?*c.GstGLDisplay = if (s.display != null) @ptrCast(@alignCast(c.gst_object_ref(s.display))) else null;
    var local: ?*c.GstGLContext = if (s.context != null) @ptrCast(@alignCast(c.gst_object_ref(s.context))) else null;
    var other: ?*c.GstGLContext = if (s.other_context != null) @ptrCast(@alignCast(c.gst_object_ref(s.other_context))) else null;
    unlock(s);
    const ret = c.gst_gl_handle_context_query(@ptrCast(s), q, display, local, other);
    clear(&display);
    clear(&other);
    clear(&local);
    if (ret != 0) return 1;
    return c.gst_pad_query_default(pad, parent, q);
}

fn srcQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (q[0].type == c.GST_QUERY_CONTEXT) return contextQuery(me(parent), pad, parent, q);
    return c.gst_pad_query_default(pad, parent, q);
}

fn srcEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    return c.gst_pad_event_default(pad, parent, e);
}

fn sinkQuery(pad: ?*c.GstPad, parent: ?*c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    const s = me(parent);
    switch (q[0].type) {
        c.GST_QUERY_CONTEXT => return contextQuery(s, pad, parent, q),
        c.GST_QUERY_ALLOCATION => return c.gst_gl_ensure_element_data(s, @ptrCast(&s.display), @ptrCast(&s.other_context)),
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            const possible = c.gst_pad_query_caps(s.sink_pad, caps);
            if (possible == null) return 0;
            const ok = c.gst_caps_is_subset(caps, possible);
            c.gst_caps_unref(possible);
            c.gst_query_set_accept_caps_result(q, ok);
            return ok;
        },
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            var left = c.gst_pad_peer_query_caps(s.left_pad, null);
            if (left == null) return 0;
            var right = c.gst_pad_peer_query_caps(s.right_pad, null);
            if (right == null) return 0;
            left = stripViews(left, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE);
            right = stripViews(right, c.GST_VIDEO_MULTIVIEW_FLAGS_NONE);
            var combined = intersectInto(left, right);
            var templ = c.gst_pad_get_pad_template_caps(s.left_pad);
            var ret = c.gst_caps_intersect_full(combined, templ, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(templ);
            c.gst_caps_unref(combined);
            combined = ret;
            if (combined == null or c.gst_caps_is_empty(combined) != 0) {
                c.gst_caps_unref(combined);
                return 0;
            }
            ret = c.gst_gl_view_convert_transform_caps(s.viewconvert, c.GST_PAD_SRC, combined, null);
            c.gst_caps_unref(combined);
            combined = ret;
            templ = c.gst_pad_get_pad_template_caps(s.sink_pad);
            ret = c.gst_caps_intersect_full(combined, templ, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(templ);
            c.gst_caps_unref(combined);
            c.gst_query_set_caps_result(q, ret);
            const ok = c.gst_caps_is_empty(ret) == 0;
            c.gst_caps_unref(ret);
            return @intFromBool(ok);
        },
        else => return c.gst_pad_query_default(pad, parent, q),
    }
}

fn sinkEvent(pad: ?*c.GstPad, parent: ?*c.GstObject, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (e[0].type == c.GST_EVENT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(e, &caps);
        const ok = setOutputCaps(me(parent), caps);
        c.gst_event_unref(e);
        return @intFromBool(ok);
    }
    return c.gst_pad_event_default(pad, parent, e);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_set_static_metadata(ec, "GLStereoSplit", "Codec/Converter", "Splits a stereoscopic stream into separate left/right streams", "Jan Schmidt <jan@centricular.com>, Matthew Waters <matthew@centricular.com>");
    @as(*c.GObjectClass, @ptrCast(@alignCast(k))).finalize = finalize;
    ec.change_state = changeState;
    ec.set_context = setContext;
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_add_static_pad_template(ec, &left_t);
    c.gst_element_class_add_static_pad_template(ec, &right_t);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.sink_pad = c.gst_pad_new_from_static_template(&sink_t, "sink");
    c.gst_pad_set_chain_function_full(s.sink_pad, chain, null, null);
    c.gst_pad_set_query_function_full(s.sink_pad, sinkQuery, null, null);
    c.gst_pad_set_event_function_full(s.sink_pad, sinkEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.sink_pad);
    s.left_pad = c.gst_pad_new_from_static_template(&left_t, "left");
    c.gst_pad_set_query_function_full(s.left_pad, srcQuery, null, null);
    c.gst_pad_set_event_function_full(s.left_pad, srcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.left_pad);
    s.right_pad = c.gst_pad_new_from_static_template(&right_t, "right");
    c.gst_pad_set_query_function_full(s.right_pad, srcQuery, null, null);
    c.gst_pad_set_event_function_full(s.right_pad, srcEvent, null, null);
    _ = c.gst_element_add_pad(@ptrCast(s), s.right_pad);
    s.viewconvert = c.gst_gl_view_convert_new();
    c.g_rec_mutex_init(&s.context_lock);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_element_get_type(), "GstGLStereoSplit", Class, Self, classInit, init);
            _ = c._gst_debug_category_new("glstereosplit", 0, "glstereosplit element");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glstereosplit", c.GST_RANK_NONE, getType());
}
