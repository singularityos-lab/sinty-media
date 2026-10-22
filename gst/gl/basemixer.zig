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

const Mix = c.GstGLBaseMixer;
const OMix = [*c]Mix;
const Class = c.GstGLBaseMixerClass;
const OAgg = [*c]c.GstAggregator;
const OCtx = [*c]c.GstGLContext;
const FILE = "gstglbasemixer.c";

const Priv = struct {
    negotiated: c.gboolean,
    other: OCtx,
    gl_started: c.gboolean,
    gl_result: c.gboolean,
    lock: c.GRecMutex,
};

const PROP_CONTEXT = 1;

var once: gtype.Once = .{};
var pad_once: gtype.Once = .{};
var priv_offset: c.gint = 0;
var parent: ?*c.GstAggregatorClass = null;

fn mx(p: anytype) OMix {
    return @ptrCast(@alignCast(p));
}

fn pv(p: anytype) *Priv {
    return @ptrCast(@alignCast(mx(p)[0].priv));
}

fn klass(p: anytype) *Class {
    return gtype.classPeek(Class, p);
}

fn eparent() *c.GstElementClass {
    return @ptrCast(@alignCast(parent.?));
}

fn lock(m: OMix) void {
    c.g_rec_mutex_lock(&pv(m).lock);
}

fn unlock(m: OMix) void {
    c.g_rec_mutex_unlock(&pv(m).lock);
}

fn clear(p: anytype) void {
    if (p.* != null) {
        c.gst_object_unref(p.*);
        p.* = null;
    }
}

fn warnInvalid(o: [*c]c.GObject, id: c.guint, spec: [*c]c.GParamSpec, line: c_int) void {
    c.g_log("GLib-GObject", c.G_LOG_LEVEL_WARNING, "%s:%d: invalid %s id %u for \"%s\" of type '%s' in '%s'", "../gst-libs/gst/gl/" ++ FILE, line, "property", id, spec[0].name, c.g_type_name(spec[0].g_type_instance.g_class[0].g_type), c.g_type_name(gtype.typeOf(o)));
}

fn padGet(o: [*c]c.GObject, id: c.guint, _: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 99);
}

fn padSet(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 110);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = padSet;
    oc.get_property = padGet;
    const vc: *c.GstVideoAggregatorPadClass = @ptrCast(@alignCast(k));
    vc.prepare_frame = null;
    vc.clean_frame = null;
}

pub export fn gst_gl_base_mixer_pad_get_type() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return gtype.objectExtending(c.gst_video_aggregator_pad_get_type, "GstGLBaseMixerPad", @sizeOf([c.GST_PADDING]c.gpointer), @sizeOf([c.GST_PADDING]c.gpointer), padClassInit, null, 0);
        }
    }.f);
}

fn findLocalDir(m: OMix, dir: c.GstPadDirection) ?bool {
    var ctx = m[0].context;
    const prev = ctx;
    unlock(m);
    const r = utils.gst_gl_query_local_gl_context(@ptrCast(m), dir, &ctx) != 0;
    lock(m);
    if (!r) return null;
    if (m[0].context != prev and m[0].context != null and m[0].context[0].display == m[0].display) {
        if (ctx != m[0].context) clear(&ctx);
        return true;
    }
    if (ctx[0].display == m[0].display) {
        m[0].context = ctx;
        return true;
    }
    if (ctx != m[0].context) clear(&ctx);
    return null;
}

fn findLocalUnlocked(m: OMix) bool {
    if (m[0].context != null and m[0].context[0].display == m[0].display) return true;
    if (findLocalDir(m, c.GST_PAD_SRC)) |r| return r;
    if (findLocalDir(m, c.GST_PAD_SINK)) |r| return r;
    return false;
}

fn glStart(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m = mx(data);
    debug.gst_gl_insert_debug_marker(m[0].context, "starting element %s", m[0].parent.aggregator.parent.object.name);
    pv(m).gl_started = klass(m).gl_start.?(m);
}

fn glStop(_: OCtx, data: c.gpointer) callconv(.c) void {
    const m = mx(data);
    debug.gst_gl_insert_debug_marker(m[0].context, "stopping element %s", m[0].parent.aggregator.parent.object.name);
    if (pv(m).gl_started != 0) klass(m).gl_stop.?(m);
    pv(m).gl_started = 0;
}

fn getContextUnlocked(m: OMix) bool {
    const k = klass(m);
    const fresh = m[0].context == null;
    var err: [*c]c.GError = null;
    if (utils.gst_gl_ensure_element_data(m, &m[0].display, &pv(m).other) == 0) return false;
    display.gst_gl_display_filter_gl_api(m[0].display, k.supported_gl_api);
    _ = findLocalUnlocked(m);
    if (display.gst_gl_display_ensure_context(m[0].display, pv(m).other, &m[0].context, &err) == 0) {
        check.elementMessage(m, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_NOT_FOUND, c.g_strdup_printf("%s", err[0].message), null, FILE, "_get_gl_context_unlocked", 239);
        c.g_clear_error(&err);
        return false;
    }
    if (fresh or pv(m).gl_started == 0) {
        if (pv(m).gl_started != 0) c.gst_gl_context_thread_add(m[0].context, glStop, m);
        if (context.gst_gl_context_get_gl_api(m[0].context) & k.supported_gl_api == 0) {
            const a = c.gst_gl_api_to_string(context.gst_gl_context_get_gl_api(m[0].context));
            const s = c.gst_gl_api_to_string(k.supported_gl_api);
            check.elementMessage(m, c.GST_MESSAGE_ERROR, c.gst_resource_error_quark(), c.GST_RESOURCE_ERROR_BUSY, c.g_strdup_printf("GL API's not compatible context: %s supported: %s", a, s), null, FILE, "_get_gl_context_unlocked", 229);
            c.g_free(s);
            c.g_free(a);
            return false;
        }
        c.gst_gl_context_thread_add(m[0].context, glStart, m);
        if (pv(m).gl_started == 0) {
            check.elementMessage(m, c.GST_MESSAGE_ERROR, c.gst_library_error_quark(), c.GST_LIBRARY_ERROR_INIT, c.g_strdup("Subclass failed to initialize."), null, FILE, "_get_gl_context_unlocked", 246);
            return false;
        }
    }
    return true;
}

fn getContext(m: OMix) bool {
    lock(m);
    defer unlock(m);
    return getContextUnlocked(m);
}

fn proposeAllocation(a: OAgg, _: ?*c.GstAggregatorPad, _: ?*c.GstQuery, _: ?*c.GstQuery) callconv(.c) c.gboolean {
    return @intFromBool(getContext(mx(a)));
}

fn contextQuery(m: OMix, q: ?*c.GstQuery) bool {
    var d: [*c]c.GstGLDisplay = null;
    var other: OCtx = null;
    var local: OCtx = null;
    lock(m);
    if (m[0].display != null) d = @ptrCast(@alignCast(c.gst_object_ref(m[0].display)));
    if (m[0].context != null) local = @ptrCast(@alignCast(c.gst_object_ref(m[0].context)));
    if (pv(m).other != null) other = @ptrCast(@alignCast(c.gst_object_ref(pv(m).other)));
    unlock(m);
    const r = utils.gst_gl_handle_context_query(@ptrCast(m), q, d, local, other) != 0;
    clear(&d);
    clear(&other);
    clear(&local);
    return r;
}

fn queryType(q: ?*c.GstQuery) c.GstQueryType {
    return @as(*c.GstQuery, @ptrCast(@alignCast(q))).type;
}

fn sinkQuery(a: OAgg, p: ?*c.GstAggregatorPad, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (queryType(q) == c.GST_QUERY_CONTEXT and contextQuery(mx(a), q)) return 1;
    return parent.?.sink_query.?(a, p, q);
}

fn srcQuery(a: OAgg, q: ?*c.GstQuery) callconv(.c) c.gboolean {
    if (queryType(q) == c.GST_QUERY_CONTEXT and contextQuery(mx(a), q)) return 1;
    return parent.?.src_query.?(a, q);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    c.g_rec_mutex_clear(&pv(o).lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn defaultGlStart(_: OMix) callconv(.c) c.gboolean {
    return 1;
}

fn defaultGlStop(_: OMix) callconv(.c) void {}

fn setContext(el: [*c]c.GstElement, ctx: ?*c.GstContext) callconv(.c) void {
    const m = mx(el);
    lock(m);
    var old: [*c]c.GstGLDisplay = if (m[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(m[0].display))) else null;
    _ = utils.gst_gl_handle_set_context(el, ctx, &m[0].display, &pv(m).other);
    if (m[0].display != null) display.gst_gl_display_filter_gl_api(m[0].display, klass(m).supported_gl_api);
    var new: [*c]c.GstGLDisplay = if (m[0].display != null) @ptrCast(@alignCast(c.gst_object_ref(m[0].display))) else null;
    if (old != null and new != null and old != new) {
        clear(&m[0].context);
        _ = getContextUnlocked(m);
        c.gst_pad_mark_reconfigure(m[0].parent.aggregator.srcpad);
    }
    clear(&old);
    clear(&new);
    unlock(m);
    eparent().set_context.?(el, ctx);
}

fn srcActivate(a: OAgg, mode: c.GstPadMode, active: c.gboolean) callconv(.c) c.gboolean {
    if (mode != c.GST_PAD_MODE_PUSH and mode != c.GST_PAD_MODE_PULL) return 1;
    if (active == 0) return 1;
    const m = mx(a);
    lock(m);
    defer unlock(m);
    if (utils.gst_gl_ensure_element_data(m, &m[0].display, &pv(m).other) == 0) return 0;
    display.gst_gl_display_filter_gl_api(m[0].display, klass(m).supported_gl_api);
    return 1;
}

fn decideAllocation(a: OAgg, _: ?*c.GstQuery) callconv(.c) c.gboolean {
    return @intFromBool(getContext(mx(a)));
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id == PROP_CONTEXT) {
        c.g_value_set_object(v, mx(o)[0].context);
        return;
    }
    warnInvalid(o, id, spec, 595);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    warnInvalid(o, id, spec, 606);
}

fn start(a: OAgg) callconv(.c) c.gboolean {
    return parent.?.start.?(a);
}

fn stop(a: OAgg) callconv(.c) c.gboolean {
    const m = mx(a);
    lock(m);
    if (pv(m).gl_started != 0) c.gst_gl_context_thread_add(m[0].context, glStop, m);
    clear(&m[0].context);
    unlock(m);
    return 1;
}

fn changeState(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const m = mx(el);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) {
        if (utils.gst_gl_ensure_element_data(el, &m[0].display, &pv(m).other) == 0) return c.GST_STATE_CHANGE_FAILURE;
        display.gst_gl_display_filter_gl_api(m[0].display, klass(m).supported_gl_api);
    }
    const r = eparent().change_state.?(el, t);
    if (r == c.GST_STATE_CHANGE_FAILURE) return r;
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        clear(&pv(m).other);
        lock(m);
        clear(&m[0].display);
        unlock(m);
    }
    return r;
}

pub export fn gst_gl_base_mixer_get_gl_context(m: OMix) OCtx {
    if (!check.that(gtype.instanceOf(m, gst_gl_base_mixer_get_type()), "gst_gl_base_mixer_get_gl_context", "GST_IS_GL_BASE_MIXER (mix)")) return null;
    lock(m);
    defer unlock(m);
    return if (m[0].context != null) @ptrCast(@alignCast(c.gst_object_ref(m[0].context))) else null;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    if (priv_offset != 0) c.g_type_class_adjust_private_offset(k, &priv_offset);
    _ = c._gst_debug_category_new("glmixer", 0, "opengl mixer");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = finalize;
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.set_context = setContext;
    ec.change_state = changeState;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.sink_query = sinkQuery;
    ac.src_query = srcQuery;
    ac.src_activate = srcActivate;
    ac.stop = stop;
    ac.start = start;
    ac.decide_allocation = decideAllocation;
    ac.propose_allocation = proposeAllocation;
    const mc: *Class = @ptrCast(@alignCast(k));
    mc.gl_start = defaultGlStart;
    mc.gl_stop = defaultGlStop;
    c.g_object_class_install_property(oc, PROP_CONTEXT, c.g_param_spec_object("context", "OpenGL context", "Get OpenGL context", context.gst_gl_context_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    _ = c.g_type_class_ref(gst_gl_base_mixer_pad_get_type());
    mc.supported_gl_api = c.GST_GL_API_ANY;
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const m = mx(inst);
    m[0].priv = @ptrCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, priv_offset))));
    pv(m).* = std.mem.zeroes(Priv);
    c.g_rec_mutex_init(&pv(m).lock);
}

pub export fn gst_gl_base_mixer_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_video_aggregator_get_type, "GstGLBaseMixer", Class, Mix, classInit, init, c.G_TYPE_FLAG_ABSTRACT);
            priv_offset = c.g_type_add_instance_private(t, @sizeOf(Priv));
            return t;
        }
    }.f);
}
