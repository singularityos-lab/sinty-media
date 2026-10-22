const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const el = @import("element.zig");

const P = struct {
    const MIXER = 1;
    const LATENCY = 2;
    const START_TIME_SELECTION = 3;
    const START_TIME = 4;
    const CONTEXT = 5;
    const FORCE_LIVE = 6;
    const MIN_UPSTREAM_LATENCY = 7;
};

pub const Private = extern struct {
    running: c.gboolean,
    chains: [*c]c.GList,
};

pub const Self = extern struct {
    parent: c.GstBin,
    mixer: [*c]c.GstElement,
    out_convert: [*c]c.GstElement,
    download: [*c]c.GstElement,
    srcpad: ?*c.GstPad,
    force_live: c.gboolean,
    latency: c.GstClockTime,
    start_time_selection: c.guint,
    start_time: c.GstClockTime,
    min_upstream_latency: c.GstClockTime,
    priv: *Private,
};

pub const Class = extern struct {
    parent: c.GstBinClass,
    create_element: ?*const fn () callconv(.c) [*c]c.GstElement,
    create_input_pad: ?*const fn (*Self, ?*c.GstPad) callconv(.c) ?*c.GstGhostPad,
};

const Chain = struct {
    self: *Self,
    ghost: ?*c.GstGhostPad = null,
    upload: [*c]c.GstElement = null,
    convert: [*c]c.GstElement = null,
    overlay: [*c]c.GstElement = null,
    mixer_pad: ?*c.GstPad = null,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "video/x-raw(ANY)");
var once: cm.Once = .{};
var sel_once: cm.Once = .{};
var offset: c.gint = 0;
var parent_el: *c.GstElementClass = undefined;
var parent_obj: *c.GObjectClass = undefined;
var sig_create: c.guint = 0;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn klass(p: anytype) *Class {
    return @ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(@alignCast(p))).g_class));
}

fn selectionType() c.GType {
    return sel_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = 0, .value_name = "Start at 0 running time (default)", .value_nick = "zero" },
            .{ .value = 1, .value_name = "Start at first observed input running time", .value_nick = "first" },
            .{ .value = 2, .value_name = "Set start time with start-time property", .value_nick = "set" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static("GstGLMixerBinStartTimeSelection", &values);
        }
    }.f);
}

fn dropElement(s: *Self, slot: *[*c]c.GstElement) void {
    if (slot.* == null) return;
    _ = c.gst_element_set_state(slot.*, c.GST_STATE_NULL);
    _ = c.gst_bin_remove(&s.parent, slot.*);
    slot.* = null;
}

fn freeChain(ch: *Chain) void {
    ch.ghost = null;
    dropElement(ch.self, &ch.upload);
    dropElement(ch.self, &ch.convert);
    dropElement(ch.self, &ch.overlay);
    if (ch.mixer_pad != null) {
        c.gst_element_release_request_pad(ch.self.mixer, ch.mixer_pad);
        c.gst_object_unref(ch.mixer_pad);
        ch.mixer_pad = null;
    }
    c.g_free(ch);
}

fn dispose(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    var l = s.priv.chains;
    while (l != null) : (l = l[0].next) {
        const ch: *Chain = @ptrCast(@alignCast(l[0].data));
        if (s.mixer != null and ch.mixer_pad != null) {
            c.gst_element_release_request_pad(s.mixer, ch.mixer_pad);
            c.gst_object_unref(ch.mixer_pad);
            ch.mixer_pad = null;
        }
    }
    c.g_list_free_full(s.priv.chains, c.g_free);
    s.priv.chains = null;
    parent_obj.dispose.?(o);
}

fn warnReached(comptime func: []const u8, line: c_int) void {
    c.g_log(null, c.G_LOG_LEVEL_WARNING, "%s:%d:%s: code should not be reached", "../ext/gl/gstglmixerbin.c", line, (func ++ "").ptr);
}

fn createChain(s: *Self, ch: *Chain, mixer_pad: ?*c.GstPad) bool {
    ch.self = s;
    ch.mixer_pad = mixer_pad;
    ch.upload = c.gst_element_factory_make("glupload", null);
    ch.convert = c.gst_element_factory_make("glcolorconvert", null);
    ch.overlay = c.gst_element_factory_make("gloverlaycompositor", null);
    var ok = c.gst_bin_add(&s.parent, ch.convert) != 0;
    ok = c.gst_bin_add(&s.parent, ch.overlay) != 0 and ok;
    ok = c.gst_bin_add(&s.parent, ch.upload) != 0 and ok;
    if (!ok) {
        warnReached("_create_input_chain", 368);
        return false;
    }
    const src = c.gst_element_get_static_pad(ch.overlay, "src");
    const linked = c.gst_pad_link(src, mixer_pad) == c.GST_PAD_LINK_OK;
    c.gst_object_unref(src);
    if (!linked) return false;
    if (c.gst_element_link_pads(ch.convert, "src", ch.overlay, "sink") == 0) {
        warnReached("_create_input_chain", 380);
        return false;
    }
    if (c.gst_element_link_pads(ch.upload, "src", ch.convert, "sink") == 0) {
        warnReached("_create_input_chain", 384);
        return false;
    }
    const pad = c.gst_element_get_static_pad(ch.upload, "sink");
    if (pad == null) return false;
    const name = c.gst_object_get_name(@ptrCast(@alignCast(mixer_pad)));
    if (klass(s).create_input_pad) |f| {
        ch.ghost = f(s, ch.mixer_pad);
        _ = c.gst_object_set_name(@ptrCast(@alignCast(ch.ghost)), name);
        _ = c.gst_ghost_pad_set_target(ch.ghost, pad);
    } else ch.ghost = @ptrCast(c.gst_ghost_pad_new(@as(*c.GstObject, @ptrCast(@alignCast(mixer_pad))).name, pad));
    c.g_free(name);
    cm.lock(s);
    if (s.priv.running != 0) _ = c.gst_pad_set_active(@ptrCast(@alignCast(ch.ghost)), 1);
    cm.unlock(s);
    _ = c.gst_element_add_pad(@ptrCast(s), @ptrCast(@alignCast(ch.ghost)));
    c.gst_object_unref(pad);
    _ = c.gst_element_sync_state_with_parent(ch.upload);
    _ = c.gst_element_sync_state_with_parent(ch.convert);
    _ = c.gst_element_sync_state_with_parent(ch.overlay);
    return true;
}

fn findTemplate(e: [*c]c.GstElement, dir: c.GstPadDirection, presence: c.GstPadPresence) [*c]c.GstPadTemplate {
    var l = c.gst_element_class_get_pad_template_list(@ptrCast(@alignCast(@as(*c.GTypeInstance, @ptrCast(e)).g_class)));
    while (l != null) : (l = l[0].next) {
        const t: [*c]c.GstPadTemplate = @ptrCast(@alignCast(l[0].data));
        if (t[0].direction == dir and t[0].presence == presence) return t;
    }
    return null;
}

fn connectMixer(s: *Self) bool {
    if (!cm.that(s.priv.chains == null, "_connect_mixer_element", "self->priv->input_chains == NULL")) return false;
    const n = c.gst_object_get_name(@ptrCast(s));
    const name = c.g_strdup_printf("%s-mixer", n);
    c.g_free(n);
    _ = c.gst_object_set_name(@ptrCast(s.mixer), name);
    c.g_free(name);
    var ok = c.gst_bin_add(&s.parent, s.mixer) != 0;
    ok = c.gst_element_link_pads(s.mixer, "src", s.out_convert, "sink") != 0 and ok;
    _ = c.gst_element_sync_state_with_parent(s.mixer);
    return ok;
}

pub fn finishInitWith(p: anytype, e: [*c]c.GstElement) void {
    const s = me(p);
    if (!cm.that(c.g_type_check_instance_is_a(@ptrCast(e), c.gst_element_get_type()) != 0, "gst_gl_mixer_bin_finish_init_with_element", "GST_IS_ELEMENT (element)")) return;
    s.mixer = e;
    if (!connectMixer(s)) {
        c.gst_object_unref(s.mixer);
        s.mixer = null;
    }
}

pub fn finishInit(p: anytype) void {
    const e = if (klass(p).create_element) |f| f() else null;
    if (e != null) finishInitWith(p, e);
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        P.MIXER => c.g_value_set_object(v, s.mixer),
        P.FORCE_LIVE => c.g_value_set_boolean(v, s.force_live),
        else => if (s.mixer != null) c.g_object_get_property(@ptrCast(s.mixer), spec[0].name, v),
    }
}

fn forward(s: *Self, spec: [*c]c.GParamSpec, v: [*c]const c.GValue) void {
    if (s.mixer != null) c.g_object_set_property(@ptrCast(s.mixer), spec[0].name, v);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        P.MIXER => {
            const m: [*c]c.GstElement = @ptrCast(@alignCast(c.g_value_get_object(v)));
            if (!cm.that(s.mixer == null or s.mixer == m, "gst_gl_mixer_bin_set_property", "!self->mixer || (self->mixer == mixer)")) return;
            s.mixer = m;
            if (m != null) {
                _ = c.gst_object_ref_sink(m);
                _ = connectMixer(s);
            }
        },
        P.FORCE_LIVE => s.force_live = c.g_value_get_boolean(v),
        P.LATENCY => {
            s.latency = c.g_value_get_uint64(v);
            forward(s, spec, v);
        },
        P.START_TIME_SELECTION => {
            s.start_time_selection = @bitCast(c.g_value_get_enum(v));
            forward(s, spec, v);
        },
        P.START_TIME => {
            s.start_time = c.g_value_get_uint64(v);
            forward(s, spec, v);
        },
        P.MIN_UPSTREAM_LATENCY => {
            s.min_upstream_latency = c.g_value_get_uint64(v);
            forward(s, spec, v);
        },
        else => forward(s, spec, v),
    }
}

fn requestPad(e: [*c]c.GstElement, t: [*c]c.GstPadTemplate, name: [*c]const u8, _: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(e);
    const ch: *Chain = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Chain))));
    ch.* = .{ .self = s };
    const mt = findTemplate(s.mixer, t[0].direction, t[0].presence);
    if (!cm.that(mt != null, "gst_gl_mixer_bin_request_new_pad", "mixer_templ")) return null;
    const mp = c.gst_element_request_pad(s.mixer, mt, name, null);
    if (!cm.that(mp != null, "gst_gl_mixer_bin_request_new_pad", "mixer_pad")) return null;
    if (!createChain(s, ch, mp)) {
        c.gst_element_release_request_pad(s.mixer, mp);
        freeChain(ch);
        return null;
    }
    cm.lock(e);
    s.priv.chains = c.g_list_prepend(s.priv.chains, ch);
    cm.unlock(e);
    c.gst_child_proxy_child_added(@ptrCast(s), @ptrCast(@alignCast(ch.ghost)), @as(*c.GstObject, @ptrCast(@alignCast(ch.ghost))).name);
    return @ptrCast(@alignCast(ch.ghost));
}

fn releasePad(e: [*c]c.GstElement, pad: ?*c.GstPad) callconv(.c) void {
    const s = me(e);
    cm.lock(e);
    var l = s.priv.chains;
    while (l != null) : (l = l[0].next) {
        const ch: *Chain = @ptrCast(@alignCast(l[0].data));
        if (@as(?*c.GstPad, @ptrCast(@alignCast(ch.ghost))) == pad) {
            s.priv.chains = c.g_list_delete_link(s.priv.chains, l);
            cm.unlock(e);
            freeChain(ch);
            _ = c.gst_element_remove_pad(e, pad);
            return;
        }
    }
    cm.unlock(e);
}

fn changeState(e: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const s = me(e);
    if (t == c.GST_STATE_CHANGE_NULL_TO_READY) {
        cm.lock(e);
        if (s.mixer == null) {
            if (klass(s).create_element) |f| s.mixer = f();
            if (s.mixer == null) c.g_signal_emit(e, sig_create, 0, &s.mixer);
            if (s.mixer == null) {
                cm.unlock(e);
                return c.GST_STATE_CHANGE_FAILURE;
            }
            cm.unlock(e);
            if (!connectMixer(s)) return c.GST_STATE_CHANGE_FAILURE;
            cm.lock(e);
        }
        s.priv.running = 1;
        cm.unlock(e);
    }
    const ret = parent_el.change_state.?(e, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    if (t == c.GST_STATE_CHANGE_READY_TO_NULL) {
        cm.lock(s);
        s.priv.running = 0;
        cm.unlock(s);
    }
    return ret;
}

fn childByIndex(cp: ?*c.GstChildProxy, index: c.guint) callconv(.c) [*c]c.GObject {
    const s = me(cp);
    const b = &s.parent;
    cm.lock(s);
    defer cm.unlock(s);
    if (index < @as(c.guint, @intCast(b.numchildren))) {
        const r = c.g_list_nth_data(b.children, index);
        if (r != null) _ = c.gst_object_ref(r);
        return @ptrCast(@alignCast(r));
    }
    const d = c.g_list_nth_data(s.priv.chains, index - @as(c.guint, @intCast(b.numchildren)));
    if (d == null) return null;
    const ch: *Chain = @ptrCast(@alignCast(d));
    return @ptrCast(@alignCast(c.gst_object_ref(ch.ghost)));
}

fn childrenCount(cp: ?*c.GstChildProxy) callconv(.c) c.guint {
    const s = me(cp);
    cm.lock(s);
    defer cm.unlock(s);
    return @as(c.guint, @intCast(s.parent.numchildren)) + c.g_list_length(s.priv.chains);
}

fn proxyInit(i: c.gpointer, _: c.gpointer) callconv(.c) void {
    const f: *c.GstChildProxyInterface = @ptrCast(@alignCast(i));
    f.get_children_count = childrenCount;
    f.get_child_by_index = childByIndex;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    c.g_type_class_adjust_private_offset(k, &offset);
    parent_el = el.parentOf(c.GstElementClass, k);
    parent_obj = el.parentOf(c.GObjectClass, k);
    _ = c._gst_debug_category_new("glmixerbin", 0, "opengl mixer bin");
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    ec.request_new_pad = requestPad;
    ec.release_pad = releasePad;
    ec.change_state = changeState;
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = getProperty;
    oc.set_property = setProperty;
    oc.dispose = dispose;
    const RW = cm.RW;
    const i = c.g_object_class_install_property;
    i(oc, P.MIXER, c.g_param_spec_object("mixer", "GL mixer element", "The GL mixer chain to use", c.gst_element_get_type(), cm.MUTABLE_READY | RW));
    i(oc, P.LATENCY, c.g_param_spec_uint64("latency", "Buffer latency", "Additional latency in live mode to allow upstream to take longer to produce buffers for the current position (in nanoseconds)", 0, std.math.maxInt(u64), 0, RW));
    i(oc, P.START_TIME_SELECTION, c.g_param_spec_enum("start-time-selection", "Start Time Selection", "Decides which start time is output", selectionType(), 0, RW));
    i(oc, P.START_TIME, c.g_param_spec_uint64("start-time", "Start Time", "Start time to use if start-time-selection=set", 0, std.math.maxInt(u64), std.math.maxInt(u64), RW));
    i(oc, P.CONTEXT, c.g_param_spec_object("context", "OpenGL context", "Get OpenGL context", c.gst_gl_context_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    i(oc, P.FORCE_LIVE, c.g_param_spec_boolean("force-live", "Force Live", "Always operate in live mode and aggregate on timeout regardless of whether any live sources are linked upstream", 0, RW | c.G_PARAM_CONSTRUCT_ONLY));
    i(oc, P.MIN_UPSTREAM_LATENCY, c.g_param_spec_uint64("min-upstream-latency", "Buffer latency", "When sources with a higher latency are expected to be plugged in dynamically after the aggregator has started playing, this allows overriding the minimum latency reported by the initial source(s). This is only taken into account when larger than the actually reported minimum latency. (nanoseconds)", 0, std.math.maxInt(u64), 0, RW));
    sig_create = c.g_signal_new("create-element", c.G_TYPE_FROM_CLASS(k), c.G_SIGNAL_RUN_LAST, 0, null, null, null, c.gst_element_get_type(), 0);
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    const caps = c.gst_gl_upload_get_input_template_caps();
    c.gst_element_class_add_pad_template(ec, c.gst_pad_template_new("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, caps));
    c.gst_caps_unref(caps);
    c.gst_element_class_set_static_metadata(ec, "OpenGL video_mixer empty bin", "Bin/Filter/Effect/Video/Mixer", "OpenGL video_mixer empty bin", "Matthew Waters <matthew@centricular.com>");
    c.gst_type_mark_as_plugin_api(selectionType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.priv = @ptrCast(@alignCast(@as([*]u8, @ptrCast(inst)) + @as(usize, @bitCast(@as(isize, offset)))));
    s.priv.* = .{ .running = 0, .chains = null };
    s.out_convert = c.gst_element_factory_make("glcolorconvert", null);
    s.download = c.gst_element_factory_make("gldownload", null);
    _ = c.gst_bin_add(&s.parent, s.out_convert);
    _ = c.gst_bin_add(&s.parent, s.download);
    _ = c.gst_element_link_pads(s.out_convert, "src", s.download, "sink");
    const p = c.gst_element_get_static_pad(s.download, "src");
    if (p != null) {
        s.srcpad = c.gst_ghost_pad_new("src", p);
        _ = c.gst_element_add_pad(@ptrCast(s), s.srcpad);
        c.gst_object_unref(p);
    }
    s.force_live = 0;
    s.latency = 0;
    s.start_time_selection = 0;
    s.start_time = std.math.maxInt(u64);
    s.min_upstream_latency = 0;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_bin_get_type(), "GstGLMixerBin", Class, Self, classInit, init);
            offset = c.g_type_add_instance_private(t, @sizeOf(Private));
            const cp = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &cp);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    return el.register(p, "glmixerbin", c.GST_RANK_NONE, getType());
}
