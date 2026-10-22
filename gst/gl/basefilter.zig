const std = @import("std");
const c = @import("../c.zig").c;
const check = @import("check.zig");
const gtype = @import("../gtype.zig");
const context = @import("context.zig");
const display = @import("display.zig");
const utils = @import("utils.zig");
const debug = @import("debug.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Filter = c.GstGLBaseFilter;
const OFilter = [*c]Filter;
const Class = c.GstGLBaseFilterClass;
const OTrans = [*c]c.GstBaseTransform;
const OCtx = [*c]c.GstGLContext;
const FILE = "gstglbasefilter.c";

const Priv = struct {
    other: OCtx,
    gl_result: c.gboolean,
    gl_started: c.gboolean,
    lock: c.GRecMutex,
    new_gl_context: c.gboolean,
};

const PROP_CONTEXT = 1;

var once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstBaseTransformClass = null;
var video_tag: c.GQuark = 0;

fn pv(f: anytype) *Priv {
    return @ptrCast(@alignCast(@as(OFilter, @ptrCast(@alignCast(f)))[0].priv));
}

fn fl(p: anytype) OFilter {
    return @ptrCast(@alignCast(p));
}

fn klass(f: anytype) *Class {
    return gtype.classPeek(Class, f);
}

fn lock(f: OFilter) void {
    c.g_rec_mutex_lock(&pv(f).lock);
}

fn unlock(f: OFilter) void {
    c.g_rec_mutex_unlock(&pv(f).lock);
}

fn clear(p: anytype) void {
    if (p.* != null) {
        c.gst_object_unref(p.*);
        p.* = null;
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const f = fl(o);
    _ = c.gst_mini_object_replace(@ptrCast(&f[0].in_caps), null);
    _ = c.gst_mini_object_replace(@ptrCast(&f[0].out_caps), null);
    c.g_rec_mutex_clear(&pv(f).lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/" ++ FILE, line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 172);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_CONTEXT) {
        c.g_value_set_object(v, fl(o)[0].context);
        return;
    }
    warnInvalid(o, id, spec, 188);
}

fn tryLocal(f: OFilter, dir: c.GstPadDirection) ?bool {
    var ctx = f[0].context;
    const prev = ctx;
    unlock(f);
    const ret = utils.gst_gl_query_local_gl_context(@ptrCast(f), dir, &ctx) != 0;
    lock(f);
    if (!ret) return null;
    if (f[0].context != prev and f[0].context != null and f[0].context[0].display == f[0].display) {
        if (ctx != f[0].context) clear(&ctx);
        return true;
    }
    if (ctx[0].display == f[0].display) {
        f[0].context = ctx;
        return true;
    }
    if (ctx != f[0].context) clear(&ctx);
    return null;
}

fn findLocalUnlocked(f: OFilter) bool {
    if (f[0].context != null and f[0].context[0].display == f[0].display) return true;
    if (tryLocal(f, c.GST_PAD_SRC)) |r| return r;
    if (tryLocal(f, c.GST_PAD_SINK)) |r| return r;
    return false;
}

fn findLocal(f: OFilter) bool {
    lock(f);
    defer unlock(f);
    return findLocalUnlocked(f);
}

fn query(t: OTrans, dir: c.GstPadDirection, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const f = fl(t);
    const qt = @as(*c.GstQuery, @ptrCast(@alignCast(q))).type;
    if (qt == c.GST_QUERY_ALLOCATION) {
        if (dir == c.GST_PAD_SINK) {
            _ = findLocal(f);
            if (c.gst_base_transform_is_passthrough(t) != 0) return c.gst_pad_peer_query(t[0].srcpad, q);
        }
    } else if (qt == c.GST_QUERY_CONTEXT) {
        var d: [*c]c.GstGLDisplay = null;
        var other: OCtx = null;
        var local: OCtx = null;
        lock(f);
        if (f[0].display != null) d = @ptrCast(@alignCast(c.gst_object_ref(f[0].display)));
        if (f[0].context != null) local = @ptrCast(@alignCast(c.gst_object_ref(f[0].context)));
        if (pv(f).other != null) other = @ptrCast(@alignCast(c.gst_object_ref(pv(f).other)));
        unlock(f);
        const r = utils.gst_gl_handle_context_query(@ptrCast(f), q, d, local, other);
        clear(&d);
        clear(&other);
        clear(&local);
        if (r != 0) return 1;
    }
    return parent.?.query.?(t, dir, q);
}

fn glStop(_: OCtx, data: c.gpointer) callconv(.c) void {
    const f = fl(data);
    debug.gst_gl_insert_debug_marker(f[0].context, "stopping element %s", f[0].parent.element.object.name);
    if (pv(f).gl_started != 0) klass(f).gl_stop.?(f);
    pv(f).gl_started = 0;
}

fn glStart(_: OCtx, data: c.gpointer) callconv(.c) void {
    const f = fl(data);
    debug.gst_gl_insert_debug_marker(f[0].context, "starting element %s", f[0].parent.element.object.name);
    pv(f).gl_started = klass(f).gl_start.?(f);
}

fn reset(f: OFilter) void {
    lock(f);
    if (f[0].context != null) {
        c.gst_gl_context_thread_add(f[0].context, glStop, f);
        c.gst_object_unref(f[0].context);
        f[0].context = null;
    }
    unlock(f);
}

fn start(_: OTrans) callconv(.c) c.gboolean {
    return 1;
}

fn stop(t: OTrans) callconv(.c) c.gboolean {
    reset(fl(t));
    return 1;
}

fn defaultGlStart(_: OFilter) callconv(.c) c.gboolean {
    return 1;
}

fn defaultGlStop(_: OFilter) callconv(.c) void {}

fn setCapsGl(_: OCtx, data: c.gpointer) callconv(.c) void {
    const f = fl(data);
    if (klass(f).gl_set_caps) |sc| pv(f).gl_result = sc(f, f[0].in_caps, f[0].out_caps);
}

fn glSetCapsUnlocked(f: OFilter) bool {
    if (klass(f).gl_set_caps == null) return true;
    c.gst_gl_context_thread_add(f[0].context, setCapsGl, f);
    return pv(f).gl_result != 0;
}

fn decideAllocation(t: OTrans, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    const f = fl(t);
    lock(f);
    if (!findGlContextUnlocked(f)) {
        unlock(f);
        return 0;
    }
    if (!glSetCapsUnlocked(f)) {
        unlock(f);
        check.elementMessage(t, c.GST_MESSAGE_ERROR, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("Subclass failed to initialize."), null, FILE, "gst_gl_base_filter_decide_allocation", 447);
        return 0;
    }
    unlock(f);
    return parent.?.decide_allocation.?(t, q);
}

fn setCaps(t: OTrans, in: ?*c.GstCaps, out: ?*c.GstCaps) callconv(.c) c.gboolean {
    const f = fl(t);
    _ = c.gst_mini_object_replace(@ptrCast(&f[0].in_caps), @ptrCast(in));
    _ = c.gst_mini_object_replace(@ptrCast(&f[0].out_caps), @ptrCast(out));
    return 1;
}

fn changeState(el: [*c]c.GstElement, tr: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const f = fl(el);
    if (tr == c.GST_STATE_CHANGE_NULL_TO_READY) {
        if (utils.gst_gl_ensure_element_data(el, &f[0].display, &pv(f).other) == 0) return c.GST_STATE_CHANGE_FAILURE;
        display.gst_gl_display_filter_gl_api(f[0].display, klass(f).supported_gl_api);
    }
    const ec: *c.GstElementClass = @ptrCast(@alignCast(parent.?));
    const r = ec.change_state.?(el, tr);
    if (r == c.GST_STATE_CHANGE_FAILURE) return r;
    if (tr == c.GST_STATE_CHANGE_READY_TO_NULL) {
        lock(f);
        clear(&pv(f).other);
        clear(&f[0].display);
        clear(&f[0].context);
        unlock(f);
    }
    return r;
}

fn setContext(el: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const f = fl(el);
    lock(f);
    var old: [*c]c.GstGLDisplay = if (f[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(f[0].display))) else null;
    _ = utils.gst_gl_handle_set_context(el, ctx, &f[0].display, &pv(f).other);
    if (f[0].display != null) display.gst_gl_display_filter_gl_api(f[0].display, klass(f).supported_gl_api);
    var new: [*c]c.GstGLDisplay = if (f[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(f[0].display))) else null;
    if (old != null and new != null and old != new) {
        clear(&f[0].context);
        if (findGlContextUnlocked(f) and f[0].in_caps != null and f[0].out_caps != null) _ = glSetCapsUnlocked(f);
    }
    unlock(f);
    clear(&old);
    clear(&new);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(parent.?));
    ec.set_context.?(el, ctx);
}

fn findGlContextUnlocked(f: OFilter) bool {
    const k = klass(f);
    var err: [*c]c.GError = null;
    const fresh = f[0].context == null;
    _ = findLocalUnlocked(f);
    if (f[0].display == null) return false;
    if (display.gst_gl_display_ensure_context(f[0].display, pv(f).other, &f[0].context, &err) == 0) {
        check.elementMessage(f, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("%s", err[0].message), null, FILE, "gst_gl_base_filter_find_gl_context_unlocked", 607);
        c.g_clear_error(&err);
        return false;
    }
    if (fresh or pv(f).gl_started == 0) {
        if (pv(f).gl_started != 0) c.gst_gl_context_thread_add(f[0].context, glStop, f);
        const api = context.gst_gl_context_get_gl_api(f[0].context);
        if (api & k.supported_gl_api == 0) {
            const a = c.gst_gl_api_to_string(api);
            const s = c.gst_gl_api_to_string(k.supported_gl_api);
            check.elementMessage(f, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, c.g_strdup_printf("GL API's not compatible context: %s supported: %s", a, s), null, FILE, "gst_gl_base_filter_find_gl_context_unlocked", 597);
            c.g_free(s);
            c.g_free(a);
            return false;
        }
        c.gst_gl_context_thread_add(f[0].context, glStart, f);
        if (pv(f).gl_started == 0) {
            check.elementMessage(f, c.GST_MESSAGE_ERROR, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("Subclass failed to initialize."), null, FILE, "gst_gl_base_filter_find_gl_context_unlocked", 614);
            return false;
        }
    }
    return true;
}

fn transformMeta(t: OTrans, out: [*c]c.GstBuffer, meta: [*c]c.GstMeta, in: [*c]c.GstBuffer) callconv(.c) c.gboolean {
    const api = meta[0].info[0].api;
    const tags = c.gst_meta_api_type_get_tags(api);
    if (tags == null or (c.g_strv_length(@ptrCast(@constCast(tags))) == 1 and c.gst_meta_api_type_has_tag(api, video_tag) != 0)) return 1;
    return parent.?.transform_meta.?(t, out, meta, in);
}

pub export fn gst_gl_base_filter_find_gl_context(f: OFilter) c.gboolean {
    lock(f);
    defer unlock(f);
    return @intFromBool(findGlContextUnlocked(f));
}

pub export fn gst_gl_base_filter_get_gl_context(f: OFilter) OCtx {
    if (!check.that(gtype.instanceOf(f, gst_gl_base_filter_get_type()), "gst_gl_base_filter_get_gl_context", "GST_IS_GL_BASE_FILTER (filter)")) return null;
    lock(f);
    defer unlock(f);
    return if (f[0].context != null) @ptrCast(@alignCast(c.gst_object_ref(f[0].context))) else null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    const tc: *c.GstBaseTransformClass = @ptrCast(@alignCast(k));
    tc.query = query;
    tc.set_caps = setCaps;
    tc.start = start;
    tc.stop = stop;
    tc.decide_allocation = decideAllocation;
    tc.transform_meta = transformMeta;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.set_context = setContext;
    ec.change_state = changeState;
    c.g_object_class_install_property(oc, PROP_CONTEXT, c.g_param_spec_object("context", "OpenGL context", "Get OpenGL context", context.gst_gl_context_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    const fc: *Class = @ptrCast(@alignCast(k));
    fc.supported_gl_api = c.GST_GL_API_ANY;
    fc.gl_start = defaultGlStart;
    fc.gl_stop = defaultGlStop;
    video_tag = c.g_quark_from_static_string("video");
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const f = fl(inst);
    c.gst_base_transform_set_qos_enabled(@ptrCast(f), 1);
    f[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(f).* = std.mem.zeroes(Priv);
    c.g_rec_mutex_init(&pv(f).lock);
}

pub export fn gst_gl_base_filter_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_base_transform_get_type, "GstGLBaseFilter", Class, Filter, classInit, init, 0);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            _ = c._gst_debug_category_new("glbasefilter", 0, "glbasefilter element");
            return t;
        }
    }.f);
}
