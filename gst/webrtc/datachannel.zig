const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");
const types = @import("types.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Channel = types.DataChannel;
const Class = types.DataChannelClass;

const FILE = "../gst-libs/gst/webrtc/datachannel.c";

const Signal = enum { open, close, err, data, string, low };

var once: gtype.Once = .{};
var parent: ?*c.GObjectClass = null;
var signals: [6]c.guint = .{0} ** 6;

fn isChannel(ch: anytype) bool {
    return gtype.instanceOf(ch, gst_webrtc_data_channel_get_type());
}

fn emit(ch: *Channel, s: Signal, arg: anytype) void {
    if (@TypeOf(arg) == void) c.g_signal_emit(ch, signals[@intFromEnum(s)], 0) else c.g_signal_emit(ch, signals[@intFromEnum(s)], 0, arg);
}

pub export fn gst_webrtc_data_channel_on_open(channel: ?*Channel) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_on_open", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    const ch = channel.?;
    c.g_mutex_lock(&ch.lock);
    const state = ch.ready_state;
    if (state == c.GST_WEBRTC_DATA_CHANNEL_STATE_CLOSING or state == c.GST_WEBRTC_DATA_CHANNEL_STATE_CLOSED) {
        c.g_mutex_unlock(&ch.lock);
        return;
    }
    ch.ready_state = c.GST_WEBRTC_DATA_CHANNEL_STATE_OPEN;
    c.g_mutex_unlock(&ch.lock);
    if (state != c.GST_WEBRTC_DATA_CHANNEL_STATE_OPEN) c.g_object_notify(@ptrCast(ch), "ready-state");
    emit(ch, .open, {});
}

pub export fn gst_webrtc_data_channel_on_close(channel: ?*Channel) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_on_close", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    const ch = channel.?;
    c.g_mutex_lock(&ch.lock);
    if (ch.ready_state == c.GST_WEBRTC_DATA_CHANNEL_STATE_CLOSED) {
        c.g_mutex_unlock(&ch.lock);
        return;
    }
    ch.ready_state = c.GST_WEBRTC_DATA_CHANNEL_STATE_CLOSED;
    c.g_mutex_unlock(&ch.lock);
    c.g_object_notify(@ptrCast(ch), "ready-state");
    emit(ch, .close, {});
}

pub export fn gst_webrtc_data_channel_on_error(channel: ?*Channel, err: [*c]c.GError) void {
    const F = "gst_webrtc_data_channel_on_error";
    if (!common.that(isChannel(channel), F, "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    if (!common.that(err != null, F, "error != NULL")) return;
    emit(channel.?, .err, err);
}

pub export fn gst_webrtc_data_channel_on_message_data(channel: ?*Channel, data: ?*c.GBytes) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_on_message_data", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    emit(channel.?, .data, data);
}

pub export fn gst_webrtc_data_channel_on_message_string(channel: ?*Channel, str: [*c]const u8) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_on_message_string", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    emit(channel.?, .string, str);
}

pub export fn gst_webrtc_data_channel_on_buffered_amount_low(channel: ?*Channel) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_on_buffered_amount_low", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    emit(channel.?, .low, {});
}

pub export fn gst_webrtc_data_channel_send_data(channel: ?*Channel, data: ?*c.GBytes) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_send_data", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    const f = gtype.classPeek(Class, channel).send_data orelse return;
    _ = f(channel.?, data, null);
}

pub export fn gst_webrtc_data_channel_send_data_full(channel: ?*Channel, data: ?*c.GBytes, err: [*c][*c]c.GError) c.gboolean {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_send_data_full", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return 0;
    const f = gtype.classPeek(Class, channel).send_data orelse return 0;
    return f(channel.?, data, err);
}

pub export fn gst_webrtc_data_channel_send_string(channel: ?*Channel, str: [*c]const u8) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_send_string", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    const f = gtype.classPeek(Class, channel).send_string orelse return;
    _ = f(channel.?, str, null);
}

pub export fn gst_webrtc_data_channel_send_string_full(channel: ?*Channel, str: [*c]const u8, err: [*c][*c]c.GError) c.gboolean {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_send_string_full", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return 0;
    const f = gtype.classPeek(Class, channel).send_string orelse return 0;
    return f(channel.?, str, err);
}

pub export fn gst_webrtc_data_channel_close(channel: ?*Channel) void {
    if (!common.that(isChannel(channel), "gst_webrtc_data_channel_close", "GST_IS_WEBRTC_DATA_CHANNEL (channel)")) return;
    const f = gtype.classPeek(Class, channel).close orelse return;
    f(channel.?);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(o));
    c.g_mutex_lock(&ch.lock);
    defer c.g_mutex_unlock(&ch.lock);
    switch (id) {
        1 => {
            c.g_free(ch.label);
            ch.label = c.g_value_dup_string(v);
        },
        2 => ch.ordered = c.g_value_get_boolean(v),
        3 => ch.max_packet_lifetime = @bitCast(c.g_value_get_int(v)),
        4 => ch.max_retransmits = @bitCast(c.g_value_get_int(v)),
        5 => {
            c.g_free(ch.protocol);
            ch.protocol = c.g_value_dup_string(v);
        },
        6 => ch.negotiated = c.g_value_get_boolean(v),
        7 => ch.id = c.g_value_get_int(v),
        8 => ch.priority = @intCast(c.g_value_get_enum(v)),
        11 => ch.buffered_amount_low_threshold = c.g_value_get_uint64(v),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(o));
    c.g_mutex_lock(&ch.lock);
    defer c.g_mutex_unlock(&ch.lock);
    switch (id) {
        1 => c.g_value_set_string(v, ch.label),
        2 => c.g_value_set_boolean(v, ch.ordered),
        3 => c.g_value_set_int(v, @bitCast(ch.max_packet_lifetime)),
        4 => c.g_value_set_int(v, @bitCast(ch.max_retransmits)),
        5 => c.g_value_set_string(v, ch.protocol),
        6 => c.g_value_set_boolean(v, ch.negotiated),
        7 => c.g_value_set_int(v, ch.id),
        8 => c.g_value_set_enum(v, @intCast(ch.priority)),
        9 => c.g_value_set_enum(v, @intCast(ch.ready_state)),
        10 => c.g_value_set_uint64(v, ch.buffered_amount),
        11 => c.g_value_set_uint64(v, ch.buffered_amount_low_threshold),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn finalize(o: [*c]c.GObject) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(o));
    c.g_free(ch.label);
    ch.label = null;
    c.g_free(ch.protocol);
    ch.protocol = null;
    c.g_mutex_clear(&ch.lock);
    parent.?.finalize.?(o);
}

fn instanceInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(inst));
    c.g_mutex_init(&ch.lock);
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    gc.finalize = finalize;
    const ss = c.G_PARAM_STATIC_STRINGS;
    const co = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss;
    const ro = c.G_PARAM_READABLE | ss;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_string("label", "Label", "Data channel label", null, co));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_boolean("ordered", "Ordered", "Using ordered transmission mode", 0, co));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_int("max-packet-lifetime", "Maximum Packet Lifetime", "Maximum number of milliseconds that transmissions and retransmissions may occur in unreliable mode (-1 = unset)", -1, std.math.maxInt(c.guint16), -1, co));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_int("max-retransmits", "Maximum Retransmits", "Maximum number of retransmissions attempted in unreliable mode", -1, std.math.maxInt(c.guint16), 0, co));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_string("protocol", "Protocol", "Data channel protocol", "", co));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_boolean("negotiated", "Negotiated", "Whether this data channel was negotiated by the application", 0, co));
    c.g_object_class_install_property(gc, 7, c.g_param_spec_int("id", "ID", "ID negotiated by this data channel (-1 = unset)", -1, std.math.maxInt(c.guint16), -1, co));
    c.g_object_class_install_property(gc, 8, c.g_param_spec_enum("priority", "Priority", "The priority of data sent using this data channel", c.gst_webrtc_priority_type_get_type(), c.GST_WEBRTC_PRIORITY_TYPE_LOW, co));
    c.g_object_class_install_property(gc, 9, c.g_param_spec_enum("ready-state", "Ready State", "The Ready state of this data channel", c.gst_webrtc_data_channel_state_get_type(), c.GST_WEBRTC_DATA_CHANNEL_STATE_CONNECTING, ro));
    c.g_object_class_install_property(gc, 10, c.g_param_spec_uint64("buffered-amount", "Buffered Amount", "The amount of data in bytes currently buffered", 0, std.math.maxInt(c.guint64), 0, ro));
    c.g_object_class_install_property(gc, 11, c.g_param_spec_uint64("buffered-amount-low-threshold", "Buffered Amount Low Threshold", "The threshold at which the buffered amount is considered low and the buffered-amount-low signal is emitted", 0, std.math.maxInt(c.guint64), 0, c.G_PARAM_READWRITE | ss));
    const t = gc.g_type_class.g_type;
    const last = c.G_SIGNAL_RUN_LAST;
    signals[@intFromEnum(Signal.open)] = c.g_signal_new("on-open", t, last, 0, null, null, null, c.G_TYPE_NONE, 0);
    signals[@intFromEnum(Signal.close)] = c.g_signal_new("on-close", t, last, 0, null, null, null, c.G_TYPE_NONE, 0);
    signals[@intFromEnum(Signal.err)] = c.g_signal_new("on-error", t, last, 0, null, null, null, c.G_TYPE_NONE, 1, c.g_error_get_type());
    signals[@intFromEnum(Signal.data)] = c.g_signal_new("on-message-data", t, last, 0, null, null, null, c.G_TYPE_NONE, 1, c.g_bytes_get_type());
    signals[@intFromEnum(Signal.string)] = c.g_signal_new("on-message-string", t, last, 0, null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_STRING);
    signals[@intFromEnum(Signal.low)] = c.g_signal_new("on-buffered-amount-low", t, last, 0, null, null, null, c.G_TYPE_NONE, 0);
    const action = last | c.G_SIGNAL_ACTION;
    _ = c.g_signal_new_class_handler("send-data", t, action | c.G_SIGNAL_DEPRECATED, @ptrCast(&gst_webrtc_data_channel_send_data), null, null, null, c.G_TYPE_NONE, 1, c.g_bytes_get_type());
    _ = c.g_signal_new_class_handler("send-string", t, action | c.G_SIGNAL_DEPRECATED, @ptrCast(&gst_webrtc_data_channel_send_string), null, null, null, c.G_TYPE_NONE, 1, c.G_TYPE_STRING);
    _ = c.g_signal_new_class_handler("close", t, action, @ptrCast(&gst_webrtc_data_channel_close), null, null, null, c.G_TYPE_NONE, 0);
}

pub export fn gst_webrtc_data_channel_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.g_object_get_type, "GstWebRTCDataChannel", Class, Channel, classInit, instanceInit, c.G_TYPE_FLAG_ABSTRACT);
            common.category("webrtcdatachannel");
            return t;
        }
    }.f);
}
