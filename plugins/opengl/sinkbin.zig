const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const P = struct {
    const FORCE_ASPECT_RATIO = 1;
    const SINK = 2;
    const SYNC = 3;
    const MAX_LATENESS = 4;
    const QOS = 5;
    const ASYNC = 6;
    const TS_OFFSET = 7;
    const ENABLE_LAST_SAMPLE = 8;
    const LAST_SAMPLE = 9;
    const BLOCKSIZE = 10;
    const RENDER_DELAY = 11;
    const THROTTLE_TIME = 12;
    const MAX_BITRATE = 13;
    const CONTRAST = 14;
    const BRIGHTNESS = 15;
    const HUE = 16;
    const SATURATION = 17;
};

pub const Self = extern struct {
    parent: c.GstBin,
    sinkpad: ?*c.GstPad,
    upload: [*c]c.GstElement,
    convert: [*c]c.GstElement,
    balance: [*c]c.GstElement,
    sink: [*c]c.GstElement,
};

pub const Class = extern struct {
    parent: c.GstBinClass,
    create_element: ?*const fn () callconv(.c) [*c]c.GstElement,
};

var once: cm.Once = .{};
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_create: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class));
}

fn connect(s: *Self) bool {
    _ = c.gst_object_set_name(@ptrCast(s.sink), "sink");
    return c.gst_bin_add(&s.parent, s.sink) != 0 and c.gst_element_link_pads(s.balance, "src", s.sink, "sink") != 0;
}

fn setSink(s: *Self, e: [*c]c.GstElement) bool {
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(e), c.gst_element_get_type()) != 0, "gst_gl_sink_bin_set_sink", "GST_IS_ELEMENT (sink)")) return false;
    if (s.sink != null) {
        _ = c.gst_element_set_locked_state(s.sink, 1);
        _ = c.gst_bin_remove(&s.parent, s.sink);
        _ = c.gst_element_set_state(s.sink, c.GST_STATE_NULL);
        c.gst_object_unref(s.sink);
        s.sink = null;
    }
    s.sink = e;
    _ = c.gst_object_ref_sink(e);
    if (!connect(s)) {
        c.gst_object_unref(s.sink);
        s.sink = null;
        return false;
    }
    return true;
}

pub fn finishInitWith(p: anytype, e: [*c]c.GstElement) void {
    _ = setSink(me(p), e);
}

pub fn finishInit(p: anytype) void {
    const e = if (klass(p).create_element) |f| f() else null;
    if (e != null) finishInitWith(p, e);
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    if (me(o).sink != null) c.gst_object_unref(me(o).sink);
    parent_obj.finalize.?(o);
}

fn balanceProp(id: c.guint) bool {
    return id == P.CONTRAST or id == P.BRIGHTNESS or id == P.HUE or id == P.SATURATION;
}

fn sinkSpec(s: *Self, spec: [*c]c.GParamSpec) bool {
    const k: *c.GObjectClass = @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(s.sink))).g_class));
    const sp = c.g_object_class_find_property(k, spec[0].name);
    return sp != null and sp[0].g_type_instance.g_class[0].g_type == spec[0].g_type_instance.g_class[0].g_type;
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == P.SINK) {
        _ = setSink(s, @ptrCast(@alignCast(c.g_value_get_object(v))));
    } else if (balanceProp(id)) {
        if (s.balance != null) c.g_object_set_property(@ptrCast(s.balance), spec[0].name, v);
    } else if (s.sink != null and sinkSpec(s, spec)) c.g_object_set_property(@ptrCast(s.sink), spec[0].name, v);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    if (id == P.SINK) {
        c.g_value_set_object(v, s.sink);
    } else if (balanceProp(id)) {
        if (s.balance != null) c.g_object_get_property(@ptrCast(s.balance), spec[0].name, v);
    } else if (s.sink != null and sinkSpec(s, spec)) c.g_object_get_property(@ptrCast(s.sink), spec[0].name, v);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY and s.sink == null) {
        if (klass(s).create_element) |f| s.sink = f();
        if (s.sink == null) {
            c.g_signal_emit(e, sig_create, 0, &s.sink);
            if (s.sink != null and c.g_object_is_floating(s.sink) != 0) _ = c.gst_object_ref_sink(s.sink);
        }
        if (s.sink == null) return c.GST_STATE_CHANGE_FAILURE;
        if (!connect(s)) return c.GST_STATE_CHANGE_FAILURE;
    }
    return parent_el.change_state.?(e, t);
}

fn byIface(p: anytype, t: c.GType) [*c]c.GstElement {
    return c.gst_bin_get_by_interface(@ptrCast(@alignCast(p)), t);
}

fn navSend(n: ?*c.GstNavigation, ev: [*c]c.GstEvent) callconv(.c) void {
    const nav = byIface(n, c.gst_navigation_get_type());
    if (nav != null) {
        c.gst_navigation_send_event_simple(@ptrCast(nav), ev);
        c.gst_object_unref(nav);
    } else _ = c.gst_element_send_event(@ptrCast(@alignCast(n)), ev);
}

fn navInit(i: c.gpointer, _: c.gpointer) callconv(.c) void {
    @as(*c.GstNavigationInterface, @ptrCast(@alignCast(i))).send_event_simple = navSend;
}

fn overlayOf(o: anytype) ?*c.GstVideoOverlay {
    return @ptrCast(byIface(o, c.gst_video_overlay_get_type()));
}

fn expose(o: ?*c.GstVideoOverlay) callconv(.c) void {
    const x = overlayOf(o) orelse return;
    c.gst_video_overlay_expose(x);
    c.gst_object_unref(x);
}

fn handleEvents(o: ?*c.GstVideoOverlay, on: c.gboolean) callconv(.c) void {
    const x = overlayOf(o) orelse return;
    c.gst_video_overlay_handle_events(x, on);
    c.gst_object_unref(x);
}

fn setRect(o: ?*c.GstVideoOverlay, x0: c.gint, y0: c.gint, w: c.gint, h: c.gint) callconv(.c) void {
    const x = overlayOf(o) orelse return;
    _ = c.gst_video_overlay_set_render_rectangle(x, x0, y0, w, h);
    c.gst_object_unref(x);
}

fn setHandle(o: ?*c.GstVideoOverlay, handle: c.guintptr) callconv(.c) void {
    const x = overlayOf(o) orelse return;
    c.gst_video_overlay_set_window_handle(x, handle);
    c.gst_object_unref(x);
}

fn overlayInit(i: c.gpointer, _: c.gpointer) callconv(.c) void {
    const f: *c.GstVideoOverlayInterface = @ptrCast(@alignCast(i));
    f.expose = expose;
    f.handle_events = handleEvents;
    f.set_render_rectangle = setRect;
    f.set_window_handle = setHandle;
}

fn balanceOf(b: anytype) ?*c.GstColorBalance {
    return @ptrCast(byIface(b, c.gst_color_balance_get_type()));
}

fn listChannels(b: ?*c.GstColorBalance) callconv(.c) [*c]const c.GList {
    const x = balanceOf(b) orelse return null;
    defer c.gst_object_unref(x);
    return c.gst_color_balance_list_channels(x);
}

fn setValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel, v: c.gint) callconv(.c) void {
    const x = balanceOf(b) orelse return;
    c.gst_color_balance_set_value(x, ch, v);
    c.gst_object_unref(x);
}

fn getValue(b: ?*c.GstColorBalance, ch: [*c]c.GstColorBalanceChannel) callconv(.c) c.gint {
    const x = balanceOf(b) orelse return 0;
    defer c.gst_object_unref(x);
    return c.gst_color_balance_get_value(x, ch);
}

fn balanceType(b: ?*c.GstColorBalance) callconv(.c) c.GstColorBalanceType {
    const x = balanceOf(b) orelse return 0;
    defer c.gst_object_unref(x);
    return c.gst_color_balance_get_balance_type(x);
}

fn balanceInit(i: c.gpointer, _: c.gpointer) callconv(.c) void {
    const f: *c.GstColorBalanceInterface = @ptrCast(@alignCast(i));
    f.list_channels = listChannels;
    f.set_value = setValue;
    f.get_value = getValue;
    f.get_balance_type = balanceType;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.change_state = changeState;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const RW = cm.RW;
    const CTL = c.GST_PARAM_CONTROLLABLE | RW;
    const i = c.g_object_class_install_property;
    i(oc, P.FORCE_ASPECT_RATIO, c.g_param_spec_boolean("force-aspect-ratio", "Force aspect ratio", "When enabled, scaling will respect original aspect ratio", 1, RW));
    i(oc, P.SINK, c.g_param_spec_object("sink", "GL sink element", "The GL sink chain to use", c.gst_element_get_type(), cm.MUTABLE_READY | RW));
    i(oc, P.SYNC, c.g_param_spec_boolean("sync", "Sync", "Sync on the clock", 1, RW));
    i(oc, P.MAX_LATENESS, c.g_param_spec_int64("max-lateness", "Max Lateness", "Maximum number of nanoseconds that a buffer can be late before it is dropped (-1 unlimited)", -1, std.math.maxInt(i64), -1, RW));
    i(oc, P.QOS, c.g_param_spec_boolean("qos", "Qos", "Generate Quality-of-Service events upstream", 0, RW));
    i(oc, P.ASYNC, c.g_param_spec_boolean("async", "Async", "Go asynchronously to PAUSED", 1, RW));
    i(oc, P.TS_OFFSET, c.g_param_spec_int64("ts-offset", "TS Offset", "Timestamp offset in nanoseconds", std.math.minInt(i64), std.math.maxInt(i64), 0, RW));
    i(oc, P.ENABLE_LAST_SAMPLE, c.g_param_spec_boolean("enable-last-sample", "Enable Last Buffer", "Enable the last-sample property", 1, RW));
    i(oc, P.LAST_SAMPLE, c.g_param_spec_boxed("last-sample", "Last Sample", "The last sample received in the sink", c.gst_sample_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    i(oc, P.BLOCKSIZE, c.g_param_spec_uint("blocksize", "Block size", "Size in bytes to pull per buffer (0 = default)", 0, std.math.maxInt(c.guint), 4096, RW));
    i(oc, P.RENDER_DELAY, c.g_param_spec_uint64("render-delay", "Render Delay", "Additional render delay of the sink in nanoseconds", 0, std.math.maxInt(u64), 0, RW));
    i(oc, P.THROTTLE_TIME, c.g_param_spec_uint64("throttle-time", "Throttle time", "The time to keep between rendered buffers (0 = disabled)", 0, std.math.maxInt(u64), 0, RW));
    i(oc, P.MAX_BITRATE, c.g_param_spec_uint64("max-bitrate", "Max Bitrate", "The maximum bits per second to render (0 = disabled)", 0, std.math.maxInt(u64), 0, RW));
    i(oc, P.CONTRAST, c.g_param_spec_double("contrast", "Contrast", "contrast", 0.0, 2.0, 1.0, CTL));
    i(oc, P.BRIGHTNESS, c.g_param_spec_double("brightness", "Brightness", "brightness", -1.0, 1.0, 0.0, CTL));
    i(oc, P.HUE, c.g_param_spec_double("hue", "Hue", "hue", -1.0, 1.0, 0.0, CTL));
    i(oc, P.SATURATION, c.g_param_spec_double("saturation", "Saturation", "saturation", 0.0, 2.0, 1.0, CTL));
    sig_create = c.g_signal_new("create-element", c.G_TYPE_FROM_CLASS(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.gst_element_get_type(), 0);
    c.gst_element_class_set_static_metadata(ec, "GL Sink Bin", "Sink/Video", "Infrastructure to process GL textures", "Matthew Waters <matthew@centricular.com>");
    const caps = c.gst_gl_upload_get_input_template_caps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, caps));
    c.gst_caps_unref(caps);
}

fn bind(s: *Self, comptime prop: [:0]const u8) void {
    _ = c.gst_object_add_control_binding(@ptrCast(s.balance), c.gst_proxy_control_binding_new(@ptrCast(s.balance), prop.ptr, @ptrCast(s), prop.ptr));
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.upload = c.gst_element_factory_make("glupload", null);
    s.convert = c.gst_element_factory_make("glcolorconvert", null);
    s.balance = c.gst_element_factory_make("glcolorbalance", null);
    _ = c.gst_bin_add(&s.parent, s.upload);
    _ = c.gst_bin_add(&s.parent, s.convert);
    _ = c.gst_bin_add(&s.parent, s.balance);
    _ = c.gst_element_link_pads(s.upload, "src", s.convert, "sink");
    _ = c.gst_element_link_pads(s.convert, "src", s.balance, "sink");
    const p = c.gst_element_get_static_pad(s.upload, "sink");
    if (p != null) {
        s.sinkpad = c.gst_ghost_pad_new("sink", p);
        _ = c.gst_element_add_pad(@ptrCast(s), s.sinkpad);
        c.gst_object_unref(p);
    }
    bind(s, "contrast");
    bind(s, "brightness");
    bind(s, "hue");
    bind(s, "saturation");
    c.gst_type_mark_as_plugin_api(getType(), 0);
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstGLSinkBin", Class, Self, classInit, init);
            const ov = c.GInterfaceInfo{ .interface_init = overlayInit, .interface_finalize = null, .interface_data = null };
            const nav = c.GInterfaceInfo{ .interface_init = navInit, .interface_finalize = null, .interface_data = null };
            const bal = c.GInterfaceInfo{ .interface_init = balanceInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_video_overlay_get_type(), &ov);
            c.g_type_add_interface_static(t, c.gst_navigation_get_type(), &nav);
            c.g_type_add_interface_static(t, c.gst_color_balance_get_type(), &bal);
            _ = c._gst_debug_category_new("glimagesink", 0, "OpenGL Video Sink Bin");
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glsinkbin", c.GST_RANK_NONE, getType());
}
