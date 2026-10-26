const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");
const types = @import("types.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Sender = types.Sender;
const Receiver = types.Receiver;
const Transceiver = types.Transceiver;

var sender_once: gtype.Once = .{};
var receiver_once: gtype.Once = .{};
var transceiver_once: gtype.Once = .{};
var sender_parent: ?*c.GObjectClass = null;
var receiver_parent: ?*c.GObjectClass = null;
var transceiver_parent: ?*c.GObjectClass = null;

pub export fn gst_webrtc_rtp_sender_set_priority(sender: ?*Sender, priority: c.GstWebRTCPriorityType) void {
    const s = sender orelse return;
    common.objectLock(s);
    s.priority = priority;
    common.objectUnlock(s);
    c.g_object_notify(@ptrCast(s), "priority");
}

pub export fn gst_webrtc_rtp_sender_new() ?*Sender {
    return @ptrCast(@alignCast(c.g_object_new(gst_webrtc_rtp_sender_get_type(), @as([*c]const u8, null))));
}

pub export fn gst_webrtc_rtp_receiver_new() ?*Receiver {
    return @ptrCast(@alignCast(c.g_object_new(gst_webrtc_rtp_receiver_get_type(), @as([*c]const u8, null))));
}

fn senderSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    switch (id) {
        1 => gst_webrtc_rtp_sender_set_priority(@ptrCast(@alignCast(o)), @intCast(c.g_value_get_enum(v))),
        else => common.warnInvalid(o, id, spec, "../gst-libs/gst/webrtc/rtpsender.c", 0),
    }
}

fn senderGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Sender = @ptrCast(@alignCast(o));
    common.objectLock(s);
    defer common.objectUnlock(s);
    switch (id) {
        1 => c.g_value_set_enum(v, @intCast(s.priority)),
        2 => c.g_value_set_object(v, s.transport),
        else => common.warnInvalid(o, id, spec, "../gst-libs/gst/webrtc/rtpsender.c", 0),
    }
}

fn senderFinalize(o: [*c]c.GObject) callconv(.c) void {
    const s: *Sender = @ptrCast(@alignCast(o));
    if (s.transport) |t| c.gst_object_unref(t);
    s.transport = null;
    sender_parent.?.finalize.?(o);
}

fn senderClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    sender_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = senderSet;
    gc.get_property = senderGet;
    gc.finalize = senderFinalize;
    const ss = c.G_PARAM_STATIC_STRINGS;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_enum("priority", "Priority", "The priority from which to set the DSCP field on packets", c.gst_webrtc_priority_type_get_type(), c.GST_WEBRTC_PRIORITY_TYPE_LOW, c.G_PARAM_READWRITE | ss));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_object("transport", "Transport", "The DTLS transport for this sender", c.gst_webrtc_dtls_transport_get_type(), c.G_PARAM_READABLE | ss));
}

pub export fn gst_webrtc_rtp_sender_get_type() c.GType {
    return sender_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCRTPSender", types.SenderClass, Sender, senderClassInit, null, 0);
            common.category("webrtcsender");
            return t;
        }
    }.f);
}

fn receiverSet(o: [*c]c.GObject, id: c.guint, _: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    common.warnInvalid(o, id, spec, "../gst-libs/gst/webrtc/rtpreceiver.c", 0);
}

fn receiverGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const r: *Receiver = @ptrCast(@alignCast(o));
    switch (id) {
        1 => {
            common.objectLock(r);
            c.g_value_set_object(v, r.transport);
            common.objectUnlock(r);
        },
        else => common.warnInvalid(o, id, spec, "../gst-libs/gst/webrtc/rtpreceiver.c", 0),
    }
}

fn receiverFinalize(o: [*c]c.GObject) callconv(.c) void {
    const r: *Receiver = @ptrCast(@alignCast(o));
    if (r.transport) |t| c.gst_object_unref(t);
    r.transport = null;
    receiver_parent.?.finalize.?(o);
}

fn receiverClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    receiver_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = receiverSet;
    gc.get_property = receiverGet;
    gc.finalize = receiverFinalize;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_object("transport", "Transport", "The DTLS transport for this receiver", c.gst_webrtc_dtls_transport_get_type(), c.G_PARAM_READABLE | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_webrtc_rtp_receiver_get_type() c.GType {
    return receiver_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCRTPReceiver", types.ReceiverClass, Receiver, receiverClassInit, null, 0);
            common.category("webrtcreceiver");
            return t;
        }
    }.f);
}

const TFILE = "../gst-libs/gst/webrtc/rtptransceiver.c";

fn transceiverSet(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(o));
    switch (id) {
        1 => x.sender = @ptrCast(@alignCast(c.g_value_dup_object(v))),
        2 => x.receiver = @ptrCast(@alignCast(c.g_value_dup_object(v))),
        4 => x.mline = c.g_value_get_uint(v),
        3 => {
            common.objectLock(x);
            x.direction = @intCast(c.g_value_get_enum(v));
            common.objectUnlock(x);
        },
        8 => {
            common.objectLock(x);
            _ = c.gst_mini_object_replace(@ptrCast(&x.codec_preferences), @ptrCast(@alignCast(c.g_value_get_boxed(v))));
            common.objectUnlock(x);
        },
        else => common.warnInvalid(o, id, spec, TFILE, 0),
    }
}

fn transceiverGet(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(o));
    switch (id) {
        5 => c.g_value_set_string(v, x.mid),
        1 => c.g_value_set_object(v, x.sender),
        2 => c.g_value_set_object(v, x.receiver),
        4 => c.g_value_set_uint(v, x.mline),
        3 => {
            common.objectLock(x);
            c.g_value_set_enum(v, @intCast(x.direction));
            common.objectUnlock(x);
        },
        6 => c.g_value_set_enum(v, @intCast(x.current_direction)),
        7 => c.g_value_set_enum(v, @intCast(x.kind)),
        8 => {
            common.objectLock(x);
            c.g_value_set_boxed(v, x.codec_preferences);
            common.objectUnlock(x);
        },
        else => common.warnInvalid(o, id, spec, TFILE, 0),
    }
}

fn transceiverConstructed(o: [*c]c.GObject) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(o));
    if (x.sender) |s| _ = c.gst_object_set_parent(@ptrCast(s), @ptrCast(x));
    if (x.receiver) |r| _ = c.gst_object_set_parent(@ptrCast(r), @ptrCast(x));
    if (transceiver_parent.?.constructed) |f| f(o);
}

fn transceiverDispose(o: [*c]c.GObject) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(o));
    if (x.sender) |s| {
        s.parent.parent = null;
        c.gst_object_unref(s);
    }
    x.sender = null;
    if (x.receiver) |r| {
        r.parent.parent = null;
        c.gst_object_unref(r);
    }
    x.receiver = null;
    transceiver_parent.?.dispose.?(o);
}

fn transceiverFinalize(o: [*c]c.GObject) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(o));
    c.g_free(x.mid);
    if (x.codec_preferences != null) c.gst_mini_object_unref(@ptrCast(x.codec_preferences));
    transceiver_parent.?.finalize.?(o);
}

fn transceiverInit(inst: [*c]c.GTypeInstance, _: c.gpointer) callconv(.c) void {
    const x: *Transceiver = @ptrCast(@alignCast(inst));
    x.direction = c.GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_NONE;
}

fn transceiverClassInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    transceiver_parent = @ptrCast(@alignCast(c.g_type_class_peek_parent(k)));
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = transceiverSet;
    gc.get_property = transceiverGet;
    gc.constructed = transceiverConstructed;
    gc.dispose = transceiverDispose;
    gc.finalize = transceiverFinalize;
    const ss = c.G_PARAM_STATIC_STRINGS;
    const co = c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | ss;
    const ro = c.G_PARAM_READABLE | ss;
    const dir = c.gst_webrtc_rtp_transceiver_direction_get_type();
    c.g_object_class_install_property(gc, 1, c.g_param_spec_object("sender", "Sender", "The RTP sender for this transceiver", gst_webrtc_rtp_sender_get_type(), co));
    c.g_object_class_install_property(gc, 2, c.g_param_spec_object("receiver", "Receiver", "The RTP receiver for this transceiver", gst_webrtc_rtp_receiver_get_type(), co));
    c.g_object_class_install_property(gc, 4, c.g_param_spec_uint("mlineindex", "Media Line Index", "Index in the SDP of the Media", 0, std.math.maxInt(c.guint), 0, co));
    c.g_object_class_install_property(gc, 3, c.g_param_spec_enum("direction", "Direction", "Transceiver direction", dir, c.GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_NONE, c.G_PARAM_READWRITE | ss));
    c.g_object_class_install_property(gc, 5, c.g_param_spec_string("mid", "Media ID", "The media ID of the m-line associated with this transceiver. This  association is established, when possible, whenever either a local or remote description is applied. This field is null if neither a local or remote description has been applied, or if its associated m-line is rejected by either a remote offer or any answer.", null, ro));
    c.g_object_class_install_property(gc, 6, c.g_param_spec_enum("current-direction", "Current Direction", "Transceiver current direction", dir, c.GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_NONE, ro));
    c.g_object_class_install_property(gc, 7, c.g_param_spec_enum("kind", "Media Kind", "Kind of media this transceiver transports", c.gst_webrtc_kind_get_type(), c.GST_WEBRTC_KIND_UNKNOWN, ro));
    c.g_object_class_install_property(gc, 8, c.g_param_spec_boxed("codec-preferences", "Codec Preferences", "Caps representing the codec preferences.", c.gst_caps_get_type(), c.G_PARAM_READWRITE | ss));
}

pub export fn gst_webrtc_rtp_transceiver_get_type() c.GType {
    return transceiver_once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCRTPTransceiver", types.TransceiverClass, Transceiver, transceiverClassInit, transceiverInit, c.G_TYPE_FLAG_ABSTRACT);
            common.category("webrtcrtptransceiver");
            return t;
        }
    }.f);
}
