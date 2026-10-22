const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;

const FILE = "../gst/playback/gstplaysinkconvertbin.c";
const N: ?*anyopaque = null;

pub const Bin = extern struct {
    parent: c.GstBin,
    lock: c.GMutex,
    sinkpad: ?*c.GstPad,
    proxypad: ?*c.GstPad,
    block_id: c.gulong,
    srcpad: ?*c.GstPad,
    raw: c.gboolean,
    elements: [*c]c.GList,
    identity: ?*c.GstElement,
    converter_caps: [*c]c.GstCaps,
    audio: c.gboolean,
};

pub const BinClass = extern struct {
    parent: c.GstBinClass,
};

pub const Audio = extern struct {
    parent: Bin,
    volume: ?*c.GstElement,
    use_converters: c.gboolean,
    use_volume: c.gboolean,
};

pub const Video = extern struct {
    parent: Bin,
    balance: ?*c.GstElement,
    use_converters: c.gboolean,
    use_balance: c.gboolean,
};

const SubClass = extern struct {
    parent: BinClass,
};

var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "ANY");
var sink_t = cm.staticTemplate("sink", c.GST_PAD_SINK, c.GST_PAD_ALWAYS, "ANY");
var bin_once: cm.Once = .{};
var audio_once: cm.Once = .{};
var video_once: cm.Once = .{};
var bin_parent: ?*c.GstElementClass = null;
var audio_parent: ?*c.GObjectClass = null;
var video_parent: ?*c.GObjectClass = null;

pub fn bin(p: anytype) *Bin {
    return @ptrCast(@alignCast(p));
}

pub fn lock(b: anytype) void {
    c.g_mutex_lock(&bin(b).lock);
}

pub fn unlock(b: anytype) void {
    c.g_mutex_unlock(&bin(b).lock);
}

fn ghost(p: ?*c.GstPad) ?*c.GstGhostPad {
    return @ptrCast(@alignCast(p));
}

fn isRaw(caps: [*c]c.GstCaps, want_audio: bool) bool {
    const prefix: []const u8 = if (want_audio) "audio/x-raw" else "video/x-raw";
    var i: c.guint = 0;
    while (i < c.gst_caps_get_size(caps)) : (i += 1) {
        const name = std.mem.span(c.gst_structure_get_name(c.gst_caps_get_structure(caps, i)));
        if (std.mem.eql(u8, name, prefix)) return true;
    }
    return false;
}

fn missing(self: *Bin, factory: [*c]const u8, comptime func: []const u8, line: c.gint) void {
    _ = c.gst_element_post_message(@ptrCast(self), c.gst_missing_element_message_new(@ptrCast(self), factory));
    const text = c.g_strdup_printf(cm.tr("gst-plugins-base-1.0", "Missing element '%s' - check your GStreamer installation."), factory);
    const dbg = c.g_strdup(if (self.audio != 0) "audio rendering might fail" else "video rendering might fail");
    cm.elementWarning(self, c.gst_core_error_quark(), c.GST_CORE_ERROR_MISSING_PLUGIN, text, dbg, FILE, func, line);
}

pub fn addElement(self: *Bin, el: ?*c.GstElement) void {
    self.elements = c.g_list_append(self.elements, el);
    _ = c.gst_bin_add(@ptrCast(self), @ptrCast(@alignCast(c.gst_object_ref(el))));
}

pub fn addFactory(self: *Bin, factory: [*c]const u8, name: [*c]const u8) ?*c.GstElement {
    const el = c.gst_element_factory_make(factory, name);
    if (el == null) missing(self, factory, "gst_play_sink_convert_bin_add_conversion_element_factory", 96) else addElement(self, el);
    return el;
}

pub fn addIdentity(self: *Bin) void {
    if (self.identity != null) return;
    self.identity = c.gst_element_factory_make("identity", "identity");
    if (self.identity == null) return missing(self, "identity", "gst_play_sink_convert_bin_add_identity", 116);
    c.g_object_set(self.identity, "silent", @as(c.gboolean, 1), "signal-handoffs", @as(c.gboolean, 0), N);
    _ = c.gst_bin_add(@ptrCast(self), self.identity);
}

fn setTargets(self: *Bin, passthrough: bool) void {
    var head: ?*c.GstElement = null;
    var tail: ?*c.GstElement = null;
    if (self.elements == null or passthrough) {
        head = self.identity;
        tail = self.identity;
    } else {
        head = @ptrCast(@alignCast(c.g_list_first(self.elements)[0].data));
        tail = @ptrCast(@alignCast(c.g_list_last(self.elements)[0].data));
    }
    if (!cm.that(head != null, "gst_play_sink_convert_bin_set_targets", "head != NULL")) return;
    if (!cm.that(tail != null, "gst_play_sink_convert_bin_set_targets", "tail != NULL")) return;
    var pad = c.gst_element_get_static_pad(head, "sink");
    _ = c.gst_ghost_pad_set_target(ghost(self.sinkpad), pad);
    c.gst_object_unref(pad);
    pad = c.gst_element_get_static_pad(tail, "src");
    _ = c.gst_ghost_pad_set_target(ghost(self.srcpad), pad);
    c.gst_object_unref(pad);
}

fn removeElement(data: c.gpointer, user: c.gpointer) callconv(.c) void {
    const el: ?*c.GstElement = @ptrCast(@alignCast(data));
    _ = c.gst_element_set_state(el, c.GST_STATE_NULL);
    c.gst_object_unref(el);
    _ = c.gst_bin_remove(@ptrCast(@alignCast(user)), el);
}

fn syncState(data: c.gpointer, _: c.gpointer) callconv(.c) void {
    _ = c.gst_element_sync_state_with_parent(@ptrCast(@alignCast(data)));
}

fn blocked(_: ?*c.GstPad, info: [*c]c.GstPadProbeInfo, user: c.gpointer) callconv(.c) c.GstPadProbeReturn {
    const self = bin(user);
    const data = info[0].data;
    if (cm.isA(data, c.gst_event_get_type()) and @as(*c.GstEvent, @ptrCast(@alignCast(data))).type & c.GST_EVENT_TYPE_SERIALIZED == 0) return c.GST_PAD_PROBE_PASS;
    lock(self);
    defer unlock(self);
    const peer = c.gst_pad_get_peer(self.sinkpad);
    var caps = c.gst_pad_get_current_caps(peer);
    if (caps == null) caps = c.gst_pad_query_caps(peer, null);
    c.gst_object_unref(peer);
    const raw = isRaw(caps, self.audio != 0);
    c.gst_caps_unref(caps);
    if (@intFromBool(raw) != self.raw) {
        self.raw = @intFromBool(raw);
        _ = c.gst_ghost_pad_set_target(ghost(self.sinkpad), null);
        _ = c.gst_ghost_pad_set_target(ghost(self.srcpad), null);
        if (raw) {
            if (self.elements != null) c.g_list_foreach(self.elements, syncState, self);
        } else syncState(self.identity, self);
        setTargets(self, !raw);
    }
    self.block_id = 0;
    return c.GST_PAD_PROBE_REMOVE;
}

fn block(self: *Bin) void {
    if (self.block_id == 0) self.block_id = c.gst_pad_add_probe(self.proxypad, c.GST_PAD_PROBE_TYPE_BLOCK_DOWNSTREAM, blocked, self, null);
}

fn unblock(self: *Bin) void {
    if (self.block_id != 0) {
        c.gst_pad_remove_probe(self.proxypad, self.block_id);
        self.block_id = 0;
    }
}

fn setCaps(self: *Bin, caps: [*c]c.GstCaps) void {
    lock(self);
    defer unlock(self);
    const name = std.mem.span(c.gst_structure_get_name(c.gst_caps_get_structure(caps, 0)));
    const raw = std.mem.eql(u8, name, if (self.audio != 0) "audio/x-raw" else "video/x-raw");
    var reconfigure = false;
    if (raw) {
        if (c.gst_pad_is_blocked(self.proxypad) == 0) {
            const target = c.gst_ghost_pad_get_target(ghost(self.sinkpad));
            if (self.raw == 0 or (target != null and c.gst_pad_query_accept_caps(target, caps) == 0)) {
                reconfigure = true;
                block(self);
            }
            if (target != null) c.gst_object_unref(target);
        }
    } else if (self.raw != 0 and c.gst_pad_is_blocked(self.proxypad) == 0) {
        reconfigure = true;
        block(self);
    }
    if (reconfigure) {
        _ = c.gst_ghost_pad_set_target(ghost(self.sinkpad), null);
        _ = c.gst_ghost_pad_set_target(ghost(self.srcpad), null);
    }
}

fn sinkEvent(pad: ?*c.GstPad, par: [*c]c.GstObject, ev: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(ev) == c.GST_EVENT_CAPS) {
        var caps: [*c]c.GstCaps = null;
        c.gst_event_parse_caps(ev, &caps);
        setCaps(bin(par), caps);
    }
    const ret = c.gst_pad_event_default(pad, par, @ptrCast(@alignCast(c.gst_mini_object_ref(@ptrCast(ev)))));
    c.gst_mini_object_unref(@ptrCast(ev));
    return ret;
}

fn otherOf(self: *Bin, pad: ?*c.GstPad) ?*c.GstPad {
    if (pad == self.srcpad) return self.sinkpad;
    if (pad == self.sinkpad) return self.srcpad;
    return null;
}

fn acceptCaps(pad: ?*c.GstPad, caps: [*c]c.GstCaps) bool {
    const self = bin(c.gst_pad_get_parent(pad));
    lock(self);
    var ret = true;
    if (otherOf(self, pad)) |o| {
        ret = c.gst_pad_peer_query_accept_caps(o, caps) != 0;
        if (!ret and self.converter_caps != null) ret = c.gst_caps_can_intersect(caps, self.converter_caps) != 0;
    }
    unlock(self);
    c.gst_object_unref(self);
    return ret;
}

fn getCaps(pad: ?*c.GstPad, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const self = bin(c.gst_pad_get_parent(pad));
    lock(self);
    var ret: [*c]c.GstCaps = null;
    if (otherOf(self, pad)) |o| {
        if (c.gst_pad_get_peer(o)) |peer| {
            var down: [*c]c.GstCaps = null;
            if (filter != null) {
                down = c.gst_caps_new_empty();
                var i: c.guint = 0;
                while (i < c.gst_caps_get_size(filter)) : (i += 1) {
                    const st = c.gst_structure_copy(c.gst_caps_get_structure(filter, i));
                    if (c.gst_structure_has_name(st, if (self.audio != 0) "audio/x-raw" else "video/x-raw") != 0) {
                        const tmp = c.gst_caps_new_full(st, N);
                        c.gst_caps_append(down, c.gst_caps_intersect(tmp, self.converter_caps));
                        c.gst_caps_unref(tmp);
                    } else c.gst_caps_append_structure(down, st);
                }
                down = c.gst_caps_merge(down, c.gst_caps_ref(self.converter_caps));
            }
            const peer_caps = c.gst_pad_query_caps(peer, down);
            if (down != null) c.gst_caps_unref(down);
            c.gst_object_unref(peer);
            if (self.converter_caps != null and isRaw(peer_caps, self.audio != 0)) {
                const conv = c.gst_caps_ref(self.converter_caps);
                ret = @ptrCast(@alignCast(c.gst_mini_object_make_writable(@ptrCast(peer_caps))));
                var i: c.guint = 0;
                while (i < c.gst_caps_get_size(conv)) : (i += 1) {
                    const st = c.gst_caps_get_structure(conv, i);
                    const cf = c.gst_caps_get_features(conv, i);
                    if (cf != null and c.gst_caps_features_is_any(cf) != 0) continue;
                    ret = c.gst_caps_merge_structure_full(ret, c.gst_structure_copy(st), if (cf != null) c.gst_caps_features_copy(cf) else null);
                }
                c.gst_caps_unref(conv);
            } else ret = peer_caps;
        } else ret = c.gst_caps_ref(self.converter_caps);
        if (filter != null) {
            const x = c.gst_caps_intersect_full(filter, ret, c.GST_CAPS_INTERSECT_FIRST);
            c.gst_caps_unref(ret);
            ret = x;
        }
    } else ret = if (filter != null) c.gst_caps_ref(filter) else c.gst_caps_new_any();
    unlock(self);
    c.gst_object_unref(self);
    return ret;
}

fn query(pad: ?*c.GstPad, par: [*c]c.GstObject, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    switch (cm.queryType(q)) {
        c.GST_QUERY_CAPS => {
            var filter: [*c]c.GstCaps = null;
            c.gst_query_parse_caps(q, &filter);
            const caps = getCaps(pad, filter);
            c.gst_query_set_caps_result(q, caps);
            c.gst_caps_unref(caps);
            return 1;
        },
        c.GST_QUERY_ACCEPT_CAPS => {
            var caps: [*c]c.GstCaps = null;
            c.gst_query_parse_accept_caps(q, &caps);
            c.gst_query_set_accept_caps_result(q, @intFromBool(acceptCaps(pad, caps)));
            return 1;
        },
        else => return c.gst_pad_query_default(pad, par, q),
    }
}

pub fn removeElements(self: *Bin) void {
    if (self.elements != null) {
        c.g_list_foreach(self.elements, removeElement, self);
        c.g_list_free(self.elements);
        self.elements = null;
    }
    if (self.converter_caps != null) {
        c.gst_caps_unref(self.converter_caps);
        self.converter_caps = null;
    }
}

pub fn cacheCaps(self: *Bin) void {
    if (self.converter_caps != null) {
        c.gst_caps_unref(self.converter_caps);
        self.converter_caps = null;
    }
    if (self.elements == null) return;
    const head: ?*c.GstElement = @ptrCast(@alignCast(c.g_list_first(self.elements)[0].data));
    const pad = c.gst_element_get_static_pad(head, "sink") orelse return;
    self.converter_caps = c.gst_pad_query_caps(pad, null);
    c.gst_object_unref(pad);
}

fn binDispose(o: [*c]c.GObject) callconv(.c) void {
    removeElements(bin(o));
    @as(*c.GObjectClass, @ptrCast(@alignCast(bin_parent.?))).dispose.?(o);
}

fn binFinalize(o: [*c]c.GObject) callconv(.c) void {
    const self = bin(o);
    c.gst_object_unref(self.proxypad);
    c.g_mutex_clear(&self.lock);
    @as(*c.GObjectClass, @ptrCast(@alignCast(bin_parent.?))).finalize.?(o);
}

fn binChange(el: [*c]c.GstElement, t: c.GstStateChange) callconv(.c) c.GstStateChangeReturn {
    const self = bin(el);
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(self);
            unblock(self);
            unlock(self);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lock(self);
            setTargets(self, true);
            self.raw = 0;
            unlock(self);
        },
        else => {},
    }
    const ret = bin_parent.?.change_state.?(el, t);
    if (ret == c.GST_STATE_CHANGE_FAILURE) return ret;
    switch (t) {
        c.GST_STATE_CHANGE_PAUSED_TO_READY => {
            lock(self);
            setTargets(self, true);
            self.raw = 0;
            unlock(self);
        },
        c.GST_STATE_CHANGE_READY_TO_PAUSED => {
            lock(self);
            unblock(self);
            unlock(self);
        },
        else => {},
    }
    return ret;
}

fn binClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    bin_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("playsinkconvertbin", 0, "play bin");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.dispose = binDispose;
    oc.finalize = binFinalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template(ec, &src_t);
    c.gst_element_class_add_static_pad_template(ec, &sink_t);
    c.gst_element_class_set_static_metadata(ec, "Player Sink Converter Bin", "Bin/Converter", "Convenience bin for audio/video conversion", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
    ec.change_state = binChange;
}

fn binInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self = bin(inst);
    c.g_mutex_init(&self.lock);
    var t = c.gst_static_pad_template_get(&sink_t);
    self.sinkpad = c.gst_ghost_pad_new_no_target_from_template("sink", t);
    c.gst_pad_set_event_function_full(self.sinkpad, sinkEvent, null, null);
    c.gst_pad_set_query_function_full(self.sinkpad, query, null, null);
    self.proxypad = @ptrCast(@alignCast(c.gst_proxy_pad_get_internal(@ptrCast(@alignCast(self.sinkpad)))));
    _ = c.gst_element_add_pad(@ptrCast(self), self.sinkpad);
    c.gst_object_unref(t);
    t = c.gst_static_pad_template_get(&src_t);
    self.srcpad = c.gst_ghost_pad_new_no_target_from_template("src", t);
    c.gst_pad_set_query_function_full(self.srcpad, query, null, null);
    _ = c.gst_element_add_pad(@ptrCast(self), self.srcpad);
    c.gst_object_unref(t);
    addIdentity(self);
}

pub fn binType() c.GType {
    return bin_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_bin_get_type(), "GstPlaySinkConvertBin", BinClass, Bin, binClassInit, binInit);
        }
    }.f);
}

fn link(a: ?*c.GstElement, b: ?*c.GstElement) bool {
    return c.gst_element_link_pads_full(a, "src", b, "sink", c.GST_PAD_LINK_CHECK_TEMPLATE_CAPS) != 0;
}

fn chainFrom(self: *Bin, first: [*c]const u8, first_name: [*c]const u8, second: [*c]const u8, second_name: [*c]const u8, prev: *?*c.GstElement) bool {
    if (addFactory(self, first, first_name)) |el| prev.* = el;
    if (addFactory(self, second, second_name)) |el| {
        if (second != null and std.mem.eql(u8, std.mem.span(second), "videoscale")) c.g_object_set(el, "add-borders", @as(c.gboolean, 1), N);
        if (prev.*) |p| {
            if (!link(p, el)) return false;
        }
        prev.* = el;
    }
    return true;
}

fn audioBuild(self: *Audio) bool {
    const b = &self.parent;
    if (b.elements != null) c.g_assertion_message_expr(null, "../gst/playback/gstplaysinkaudioconvert.c", 52, "gst_play_sink_audio_convert_add_conversion_elements", "cbin->conversion_elements == NULL");
    var prev: ?*c.GstElement = null;
    if (self.use_converters != 0 and !chainFrom(b, "audioconvert", "conv", "audioresample", "resample", &prev)) return false;
    if (self.use_volume != 0 and self.volume != null) {
        addElement(b, self.volume);
        if (prev) |p| {
            if (!link(p, self.volume)) return false;
        }
    }
    return true;
}

fn videoBuild(self: *Video) bool {
    const b = &self.parent;
    if (b.elements != null) c.g_assertion_message_expr(null, "../gst/playback/gstplaysinkvideoconvert.c", 51, "gst_play_sink_video_convert_add_conversion_elements", "cbin->conversion_elements == NULL");
    var prev: ?*c.GstElement = null;
    if (self.use_converters != 0 and !chainFrom(b, "videoconvert", "conv", "videoscale", "scale", &prev)) return false;
    if (self.use_balance != 0 and self.balance != null) {
        addElement(b, self.balance);
        if (prev) |p| {
            if (!link(p, self.balance)) return false;
        }
        prev = self.balance;
        const el = addFactory(b, "videoconvert", "conv2");
        if (prev) |p| {
            if (!link(p, el)) return false;
        }
    }
    return true;
}

const PROP_USE_CONVERTERS = 1;
const PROP_USE_EXTRA = 2;
const PROP_VOLUME_ELEMENT = 3;

fn audio(p: anytype) *Audio {
    return @ptrCast(@alignCast(p));
}

fn video(p: anytype) *Video {
    return @ptrCast(@alignCast(p));
}

fn rebuild(b: *Bin, comptime build: anytype, self: anytype) void {
    removeElements(b);
    _ = build(self);
    addIdentity(b);
    cacheCaps(b);
}

fn audioSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const self = audio(o);
    lock(self);
    defer unlock(self);
    const val = c.g_value_get_boolean(v);
    const field = switch (id) {
        PROP_USE_CONVERTERS => &self.use_converters,
        PROP_USE_EXTRA => &self.use_volume,
        else => return,
    };
    if (val == field.*) return;
    field.* = val;
    rebuild(&self.parent, audioBuild, self);
}

fn audioGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const self = audio(o);
    lock(self);
    defer unlock(self);
    switch (id) {
        PROP_USE_CONVERTERS => c.g_value_set_boolean(v, self.use_converters),
        PROP_USE_EXTRA => c.g_value_set_boolean(v, self.use_volume),
        PROP_VOLUME_ELEMENT => c.g_value_set_object(v, self.volume),
        else => {},
    }
}

fn audioFinalize(o: [*c]c.GObject) callconv(.c) void {
    if (audio(o).volume) |v| c.gst_object_unref(v);
    audio_parent.?.finalize.?(o);
}

fn audioClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    audio_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("playsinkaudioconvert", 0, "play bin");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = audioFinalize;
    oc.set_property = audioSet;
    oc.get_property = audioGet;
    c.g_object_class_install_property(oc, PROP_USE_CONVERTERS, c.g_param_spec_boolean("use-converters", "Use converters", "Whether to use conversion elements", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_EXTRA, c.g_param_spec_boolean("use-volume", "Use volume", "Whether to use a volume element", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_VOLUME_ELEMENT, c.g_param_spec_object("volume-element", "Volume element", "Retrieve the soft-volume element used when use-volume=TRUE", c.gst_element_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Player Sink Audio Converter", "Audio/Bin/Converter", "Convenience bin for audio conversion", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
}

fn audioInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self = audio(inst);
    self.parent.audio = 1;
    self.volume = c.gst_element_factory_make("volume", "volume");
    if (self.volume != null) _ = c.gst_object_ref_sink(self.volume);
    _ = audioBuild(self);
    cacheCaps(&self.parent);
}

pub fn audioType() c.GType {
    return audio_once.get(struct {
        fn f() c.GType {
            return cm.register(binType(), "GstPlaySinkAudioConvert", SubClass, Audio, audioClassInit, audioInit);
        }
    }.f);
}

fn videoSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const self = video(o);
    lock(self);
    defer unlock(self);
    const val = c.g_value_get_boolean(v);
    const field = switch (id) {
        PROP_USE_CONVERTERS => &self.use_converters,
        PROP_USE_EXTRA => &self.use_balance,
        else => return,
    };
    if (val == field.*) return;
    field.* = val;
    rebuild(&self.parent, videoBuild, self);
}

fn videoGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, _: [*c]c.GParamSpec) callconv(.c) void {
    const self = video(o);
    lock(self);
    defer unlock(self);
    switch (id) {
        PROP_USE_CONVERTERS => c.g_value_set_boolean(v, self.use_converters),
        PROP_USE_EXTRA => c.g_value_set_boolean(v, self.use_balance),
        else => {},
    }
}

fn videoFinalize(o: [*c]c.GObject) callconv(.c) void {
    if (video(o).balance) |b| c.gst_object_unref(b);
    video_parent.?.finalize.?(o);
}

fn videoClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    video_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("playsinkvideoconvert", 0, "play bin");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.finalize = videoFinalize;
    oc.set_property = videoSet;
    oc.get_property = videoGet;
    c.g_object_class_install_property(oc, PROP_USE_CONVERTERS, c.g_param_spec_boolean("use-converters", "Use converters", "Whether to use conversion elements", 0, cm.RW));
    c.g_object_class_install_property(oc, PROP_USE_EXTRA, c.g_param_spec_boolean("use-balance", "Use balance", "Whether to use a videobalance element", 0, cm.RW));
    c.gst_element_class_set_static_metadata(@ptrCast(@alignCast(k)), "Player Sink Video Converter", "Video/Bin/Converter", "Convenience bin for video conversion", "Sebastian Dröge <sebastian.droege@collabora.co.uk>");
}

fn videoInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const self = video(inst);
    self.parent.audio = 0;
    self.balance = c.gst_element_factory_make("videobalance", "videobalance");
    if (self.balance != null) _ = c.gst_object_ref_sink(self.balance);
    _ = videoBuild(self);
    cacheCaps(&self.parent);
}

pub fn videoType() c.GType {
    return video_once.get(struct {
        fn f() c.GType {
            return cm.register(binType(), "GstPlaySinkVideoConvert", SubClass, Video, videoClassInit, videoInit);
        }
    }.f);
}
