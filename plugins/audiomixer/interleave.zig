const std = @import("std");
const cm = @import("../common.zig");
const c = cm.c;
const pads = @import("pads.zig");
const mixer = @import("mixer.zig");

const FILE = "../gst/audiomixer/gstaudiointerleave.c";
const PROP_PAD_CHANNEL = 1;
const PROP_CHANNEL_POSITIONS = 1;
const PROP_CHANNEL_POSITIONS_FROM_INPUT = 2;

const Func = *const fn ([*]u8, [*]const u8, c.guint, c.guint) void;

const Pad = extern struct {
    parent: pads.APad,
    channel: c.guint,
};

const PadClass = extern struct {
    parent: c.GstAudioAggregatorPadClass,
};

const Self = extern struct {
    parent: c.GstAudioAggregator,
    padcounter: c.gint,
    channels: c.guint,
    sinkcaps: [*c]c.GstCaps,
    channel_positions: ?*c.GValueArray,
    input_channel_positions: ?*c.GValueArray,
    channel_positions_from_input: c.gboolean,
    default_channels_ordering_map: [64]c.gint,
    func: ?Func,
};

const Class = extern struct {
    parent: c.GstAudioAggregatorClass,
};

var sink_t = cm.staticTemplate("sink_%u", c.GST_PAD_SINK, c.GST_PAD_REQUEST, "audio/x-raw, rate = (int) [ 1, MAX ], channels = (int) 1, format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", layout = (string) {non-interleaved, interleaved}");
var src_t = cm.staticTemplate("src", c.GST_PAD_SRC, c.GST_PAD_ALWAYS, "audio/x-raw, rate = (int) [ 1, MAX ], channels = (int) [ 1, MAX ], format = (string) " ++ c.GST_AUDIO_FORMATS_ALL ++ ", layout = (string) interleaved");
var once: cm.Once = .{};
var pad_once: cm.Once = .{};
var parent: ?*c.GstAggregatorClass = null;

fn me(p: anytype) *Self {
    return @ptrCast(@alignCast(p));
}

fn ipad(p: anytype) *Pad {
    return @ptrCast(@alignCast(p));
}

fn padGetProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    if (id != PROP_PAD_CHANNEL) return cm.warnInvalid(FILE, o, id, spec, 72);
    c.g_value_set_uint(v, ipad(o).channel);
}

fn padClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.get_property = padGetProperty;
    c.g_object_class_install_property(oc, PROP_PAD_CHANNEL, c.g_param_spec_uint("channel", "Channel number", "Number of the channel of this pad in the output", 0, std.math.maxInt(c.guint), 0, c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
}

fn padInit(_: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {}

fn padType() c.GType {
    return pad_once.get(struct {
        fn f() c.GType {
            return cm.register(c.gst_audio_aggregator_pad_get_type(), "GstAudioInterleavePad", PadClass, Pad, padClassInit, padInit);
        }
    }.f);
}

fn removeChannels(caps: [*c]c.GstCaps) void {
    for (0..c.gst_caps_get_size(caps)) |i| {
        const st = c.gst_caps_get_structure(caps, @intCast(i));
        c.gst_structure_remove_field(st, "channel-mask");
        c.gst_structure_remove_field(st, "channels");
    }
}

fn setChannels(caps: [*c]c.GstCaps, n: c.gint) void {
    for (0..c.gst_caps_get_size(caps)) |i| {
        const st = c.gst_caps_get_structure(caps, @intCast(i));
        if (n > 0) {
            c.gst_structure_set_static_str(st, "channels", c.G_TYPE_INT, n, @as(?*anyopaque, null));
        } else c.gst_structure_set_static_str(st, "channels", c.gst_int_range_get_type(), @as(c.gint, 1), @as(c.gint, std.math.maxInt(c.gint)), @as(?*anyopaque, null));
    }
}

fn sinkGetCaps(agg: [*c]c.GstAggregator, p: ?*c.GstPad, filter: [*c]c.GstCaps) [*c]c.GstCaps {
    const s = me(agg);
    var result: [*c]c.GstCaps = null;
    cm.lock(s);
    if (s.sinkcaps != null) result = c.gst_caps_copy(s.sinkcaps);
    cm.unlock(s);
    if (result == null) {
        var peer = c.gst_pad_peer_query_caps(agg.*.srcpad, null);
        const tcaps = c.gst_pad_get_pad_template_caps(p);
        const sinkcaps = c.gst_caps_copy(tcaps);
        c.gst_caps_unref(tcaps);
        removeChannels(sinkcaps);
        if (peer != null) {
            peer = c.gst_caps_make_writable(peer);
            removeChannels(peer);
            result = c.gst_caps_intersect(peer, sinkcaps);
            c.gst_caps_unref(peer);
            c.gst_caps_unref(sinkcaps);
        } else result = sinkcaps;
        setChannels(result, 1);
    }
    if (filter != null) {
        const tmp = result;
        result = c.gst_caps_intersect_full(filter, tmp, c.GST_CAPS_INTERSECT_FIRST);
        c.gst_caps_unref(tmp);
    }
    return result;
}

fn sinkQuery(agg: [*c]c.GstAggregator, p: ?*c.GstAggregatorPad, q: [*c]c.GstQuery) callconv(.c) c.gboolean {
    if (cm.queryType(q) != c.GST_QUERY_CAPS) return parent.?.sink_query.?(agg, p, q);
    var filter: [*c]c.GstCaps = null;
    c.gst_query_parse_caps(q, &filter);
    const caps = sinkGetCaps(agg, @ptrCast(p), filter);
    c.gst_query_set_caps_result(q, caps);
    c.gst_caps_unref(caps);
    return 1;
}

fn comparePositions(a: c.gconstpointer, b: c.gconstpointer, data: c.gpointer) callconv(.c) c.gint {
    const pos: [*]const c.gint = @ptrCast(@alignCast(data));
    const i: usize = @intCast(@as(*const c.gint, @ptrCast(@alignCast(a))).*);
    const j: usize = @intCast(@as(*const c.gint, @ptrCast(@alignCast(b))).*);
    if (pos[i] < pos[j]) return -1;
    if (pos[i] > pos[j]) return 1;
    return 0;
}

fn positionsToMask(positions: *c.GValueArray, map: *[64]c.gint, mask: *u64) bool {
    const n = positions.n_values;
    const pos: [*]c.GstAudioChannelPosition = @ptrCast(@alignCast(c.g_malloc(@sizeOf(c.GstAudioChannelPosition) * n)));
    defer c.g_free(pos);
    for (0..n) |i| pos[i] = c.g_value_get_enum(c.g_value_array_get_nth(positions, @intCast(i)));
    for (0..n) |i| map[i] = @intCast(i);
    c.g_sort_array(map, n, @sizeOf(c.gint), comparePositions, pos);
    return c.gst_audio_channel_positions_to_mask(pos, @intCast(n), 0, mask) != 0;
}

fn channelMask(s: *Self) u64 {
    var mask: u64 = 0;
    if (s.channels <= 64) {
        if (s.channel_positions) |cp| {
            if (s.channels == cp.n_values and !positionsToMask(cp, &s.default_channels_ordering_map, &mask)) mask = 0;
        }
    }
    return mask;
}

fn interleave(comptime T: type) Func {
    return struct {
        fn f(out: [*]u8, in: [*]const u8, stride: c.guint, n: c.guint) void {
            var o: [*]align(1) T = @ptrCast(out);
            const i: [*]align(1) const T = @ptrCast(in);
            for (0..n) |k| {
                o[0] = i[k];
                o += stride;
            }
        }
    }.f;
}

fn interleave24(out: [*]u8, in: [*]const u8, stride: c.guint, n: c.guint) void {
    var o = out;
    var i = in;
    for (0..n) |_| {
        @memcpy(o[0..3], i[0..3]);
        o += @as(usize, stride) * 3;
        i += 3;
    }
}

fn setProcessFunction(s: *Self, info: *const c.GstAudioInfo) void {
    s.func = switch (info.finfo.*.width) {
        8 => interleave(u8),
        16 => interleave(u16),
        24 => interleave24,
        32 => interleave(u32),
        64 => interleave(u64),
        else => unreachable,
    };
}

fn setCaps(s: *Self, p: ?*c.GstAggregatorPad, caps: [*c]c.GstCaps) bool {
    var info: c.GstAudioInfo = undefined;
    if (c.gst_audio_info_from_caps(&info, caps) == 0) return false;
    cm.lock(s);
    if (s.sinkcaps != null and c.gst_caps_is_subset(caps, s.sinkcaps) == 0) {
        cm.unlock(s);
        return false;
    }
    if (s.sinkcaps == null) {
        const copy = c.gst_caps_copy(caps);
        c.gst_structure_remove_field(c.gst_caps_get_structure(copy, 0), "channel-mask");
        _ = c.gst_caps_replace(&s.sinkcaps, copy);
        c.gst_pad_mark_reconfigure(@as(*c.GstAggregator, @ptrCast(@alignCast(s))).srcpad);
        c.gst_caps_unref(copy);
    }
    if (s.channel_positions_from_input != 0 and info.channels == 1) {
        const v = c.g_value_array_get_nth(s.input_channel_positions, ipad(p).channel);
        c.g_value_set_enum(v, info.position[0]);
    }
    cm.unlock(s);
    c.gst_audio_aggregator_set_sink_caps(@ptrCast(s), @ptrCast(p), caps);
    return true;
}

fn sinkEvent(agg: [*c]c.GstAggregator, p: ?*c.GstAggregatorPad, e: [*c]c.GstEvent) callconv(.c) c.gboolean {
    if (cm.eventType(e) != c.GST_EVENT_CAPS) return parent.?.sink_event.?(agg, p, e);
    var caps: [*c]c.GstCaps = null;
    c.gst_event_parse_caps(e, &caps);
    const ok = setCaps(me(agg), p, caps);
    c.gst_event_unref(e);
    return @intFromBool(ok);
}

fn updateSrcCaps(agg: [*c]c.GstAggregator, _: [*c]c.GstCaps, ret: [*c][*c]c.GstCaps) callconv(.c) c.GstFlowReturn {
    const s = me(agg);
    cm.lock(s);
    defer cm.unlock(s);
    if (s.sinkcaps == null or s.channels == 0) return c.GST_FLOW_NOT_NEGOTIATED;
    ret.* = c.gst_caps_copy(s.sinkcaps);
    const st = c.gst_caps_get_structure(ret.*, 0);
    c.gst_structure_set_static_str(st, "channels", c.G_TYPE_INT, s.channels, "layout", c.G_TYPE_STRING, "interleaved", "channel-mask", c.gst_bitmask_get_type(), channelMask(s), @as(?*anyopaque, null));
    return c.GST_FLOW_OK;
}

fn negotiatedSrcCaps(agg: [*c]c.GstAggregator, caps: [*c]c.GstCaps) callconv(.c) c.gboolean {
    if (parent.?.negotiated_src_caps.?(agg, caps) == 0) return 0;
    setProcessFunction(me(agg), &pads.apad(agg.*.srcpad).info);
    return 1;
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const s = me(o);
    if (s.channel_positions != null and s.channel_positions != s.input_channel_positions) {
        c.g_value_array_free(s.channel_positions);
        s.channel_positions = null;
    }
    if (s.input_channel_positions) |x| c.g_value_array_free(x);
    s.input_channel_positions = null;
    @as(*c.GObjectClass, @ptrCast(@alignCast(parent.?))).finalize.?(o);
}

fn dropOwnPositions(s: *Self) void {
    if (s.channel_positions != null and s.channel_positions != s.input_channel_positions) c.g_value_array_free(s.channel_positions);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CHANNEL_POSITIONS => {
            const arr: *c.GValueArray = @ptrCast(@alignCast(c.g_value_get_boxed(v)));
            if (!cm.that(arr.n_values > 0, "gst_audio_interleave_set_property", "((GValueArray *) g_value_get_boxed (value))->n_values > 0")) return;
            dropOwnPositions(s);
            s.channel_positions = @ptrCast(@alignCast(c.g_value_dup_boxed(v)));
            s.channel_positions_from_input = 0;
        },
        PROP_CHANNEL_POSITIONS_FROM_INPUT => {
            s.channel_positions_from_input = c.g_value_get_boolean(v);
            if (s.channel_positions_from_input != 0) {
                dropOwnPositions(s);
                s.channel_positions = s.input_channel_positions;
            }
        },
        else => cm.warnInvalid(FILE, o, id, spec, 679),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s = me(o);
    switch (id) {
        PROP_CHANNEL_POSITIONS => c.g_value_set_boxed(v, s.channel_positions),
        PROP_CHANNEL_POSITIONS_FROM_INPUT => c.g_value_set_boolean(v, s.channel_positions_from_input),
        else => cm.warnInvalid(FILE, o, id, spec, 698),
    }
}

fn stop(agg: [*c]c.GstAggregator) callconv(.c) c.gboolean {
    if (parent.?.stop.?(agg) == 0) return 0;
    _ = c.gst_caps_replace(&me(agg).sinkcaps, null);
    return 1;
}

fn requestNewPad(el: [*c]c.GstElement, templ: [*c]c.GstPadTemplate, _: [*c]const u8, caps: [*c]const c.GstCaps) callconv(.c) ?*c.GstPad {
    const s = me(el);
    cm.lock(s);
    const number = c.g_atomic_int_add(&s.padcounter, 1);
    var channel: c.guint = s.channels;
    s.channels += 1;
    if (s.channel_positions_from_input == 0) channel = @bitCast(number);
    cm.unlock(s);
    const name = c.g_strdup_printf("sink_%u", number);
    const ec: *c.GstElementClass = @ptrCast(@alignCast(parent.?));
    const p = ec.request_new_pad.?(el, templ, name, caps);
    c.g_free(name);
    if (p == null) return null;
    ipad(p).channel = channel;
    c.gst_pad_use_fixed_caps(p);
    c.gst_child_proxy_child_added(@ptrCast(el), @ptrCast(@alignCast(p)), cm.obj(p).name);
    var val = std.mem.zeroes(c.GValue);
    _ = c.g_value_init(&val, c.gst_audio_channel_position_get_type());
    c.g_value_set_enum(&val, c.GST_AUDIO_CHANNEL_POSITION_NONE);
    s.input_channel_positions = c.g_value_array_append(s.input_channel_positions, &val);
    c.g_value_unset(&val);
    c.gst_pad_mark_reconfigure(@as(*c.GstAggregator, @ptrCast(@alignCast(s))).srcpad);
    return p;
}

fn releasePad(el: [*c]c.GstElement, p: ?*c.GstPad) callconv(.c) void {
    const s = me(el);
    cm.lock(s);
    s.channels -%= 1;
    const position = ipad(p).channel;
    _ = c.g_value_array_remove(s.input_channel_positions, position);
    var l = @as(*c.GstElement, @ptrCast(@alignCast(s))).sinkpads;
    while (l != null) : (l = l.*.next) {
        const other = ipad(l.*.data);
        if (ipad(p).channel < other.channel) other.channel -= 1;
    }
    c.gst_pad_mark_reconfigure(@as(*c.GstAggregator, @ptrCast(@alignCast(s))).srcpad);
    cm.unlock(s);
    c.gst_child_proxy_child_removed(@ptrCast(el), @ptrCast(@alignCast(p)), cm.obj(p).name);
    @as(*c.GstElementClass, @ptrCast(@alignCast(parent.?))).release_pad.?(el, p);
}

fn aggregateOne(aagg: [*c]c.GstAudioAggregator, apad: ?*c.GstAudioAggregatorPad, in: [*c]c.GstBuffer, in_off: c.guint, out: [*c]c.GstBuffer, out_off: c.guint, frames: c.guint) callconv(.c) c.gboolean {
    const s = me(aagg);
    const p = ipad(apad);
    const srcpad = pads.apad(@as(*c.GstAggregator, @ptrCast(@alignCast(aagg))).srcpad);
    cm.lock(aagg);
    cm.lock(apad);
    defer {
        cm.unlock(apad);
        cm.unlock(aagg);
    }
    const width: usize = @intCast(@divTrunc(srcpad.info.finfo.*.width, 8));
    const in_bpf: usize = @intCast(pads.apad(apad).info.bpf);
    const out_bpf: usize = @intCast(srcpad.info.bpf);
    const out_channels: c.guint = @intCast(srcpad.info.channels);
    var omap: c.GstMapInfo = undefined;
    var imap: c.GstMapInfo = undefined;
    _ = c.gst_buffer_map(out, &omap, c.GST_MAP_READWRITE);
    _ = c.gst_buffer_map(in, &imap, c.GST_MAP_READ);
    const channel: usize = @intCast(if (s.channels > 64) @as(c.gint, @bitCast(p.channel)) else s.default_channels_ordering_map[p.channel]);
    const dst = omap.data + out_off * out_bpf + width * channel;
    s.func.?(dst, imap.data + in_off * in_bpf, out_channels, frames);
    c.gst_buffer_unmap(in, &imap);
    c.gst_buffer_unmap(out, &omap);
    return 1;
}

fn proxyInit(g: c.gpointer, _: c.gpointer) callconv(.c) void {
    const i: *c.GstChildProxyInterface = @ptrCast(@alignCast(g));
    i.get_child_by_index = mixer.childByIndex;
    i.get_children_count = mixer.childrenCount;
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    _ = c._gst_debug_category_new("audiointerleave", 0, "audio interleaving element");
    const oc: *c.GObjectClass = @ptrCast(@alignCast(k));
    oc.set_property = setProperty;
    oc.get_property = getProperty;
    oc.finalize = finalize;
    const ec: *c.GstElementClass = @ptrCast(@alignCast(k));
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &src_t, c.gst_audio_aggregator_pad_get_type());
    c.gst_element_class_add_static_pad_template_with_gtype(ec, &sink_t, padType());
    c.gst_element_class_set_static_metadata(ec, "AudioInterleave", "Generic/Audio", "Mixes multiple audio streams", "Olivier Crete <olivier.crete@collabora.com>");
    ec.request_new_pad = requestNewPad;
    ec.release_pad = releasePad;
    const ac: *c.GstAggregatorClass = @ptrCast(@alignCast(k));
    ac.sink_query = sinkQuery;
    ac.sink_event = sinkEvent;
    ac.stop = stop;
    ac.update_src_caps = updateSrcCaps;
    ac.negotiated_src_caps = negotiatedSrcCaps;
    @as(*c.GstAudioAggregatorClass, @ptrCast(@alignCast(k))).aggregate_one_buffer = aggregateOne;
    c.g_object_class_install_property(oc, PROP_CHANNEL_POSITIONS, c.g_param_spec_value_array("channel-positions", "Channel positions", "Channel positions used on the output", c.g_param_spec_enum("channel-position", "Channel position", "Channel position of the n-th input", c.gst_audio_channel_position_get_type(), c.GST_AUDIO_CHANNEL_POSITION_NONE, cm.RW), cm.RW));
    c.g_object_class_install_property(oc, PROP_CHANNEL_POSITIONS_FROM_INPUT, c.g_param_spec_boolean("channel-positions-from-input", "Channel positions from input", "Take channel positions from the input", 1, cm.RW));
    c.gst_type_mark_as_plugin_api(padType(), 0);
}

fn init(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const s = me(inst);
    s.input_channel_positions = c.g_value_array_new(0);
    s.channel_positions_from_input = 1;
    s.channel_positions = s.input_channel_positions;
}

pub fn getType() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = cm.register(c.gst_audio_aggregator_get_type(), "GstAudioInterleave", Class, Self, classInit, init);
            const info = c.GInterfaceInfo{ .interface_init = proxyInit, .interface_finalize = null, .interface_data = null };
            c.g_type_add_interface_static(t, c.gst_child_proxy_get_type(), &info);
            return t;
        }
    }.f);
}

pub fn register(p: ?*c.GstPlugin) bool {
    mixer.elementInit();
    return c.gst_element_register(p, "audiointerleave", c.GST_RANK_NONE, getType()) != 0;
}
