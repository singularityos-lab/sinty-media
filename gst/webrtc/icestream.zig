const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Stream = c.GstWebRTCICEStream;
const Class = c.GstWebRTCICEStreamClass;

const FILE = "../gst-libs/gst/webrtc/icestream.c";

var once: gtype.Once = .{};

pub export fn gst_webrtc_ice_stream_find_transport(stream: [*c]Stream, component: c.GstWebRTCICEComponent) [*c]c.GstWebRTCICETransport {
    if (!common.that(gtype.instanceOf(stream, gst_webrtc_ice_stream_get_type()), "gst_webrtc_ice_stream_find_transport", "GST_IS_WEBRTC_ICE_STREAM (stream)")) return null;
    const f = gtype.classPeek(Class, stream).find_transport orelse return null;
    return f(stream, component);
}

pub export fn gst_webrtc_ice_stream_gather_candidates(stream: [*c]Stream) c.gboolean {
    if (!common.that(gtype.instanceOf(stream, gst_webrtc_ice_stream_get_type()), "gst_webrtc_ice_stream_gather_candidates", "GST_IS_WEBRTC_ICE_STREAM (stream)")) return 0;
    const f = gtype.classPeek(Class, stream).gather_candidates orelse return 0;
    return f(stream);
}

fn setProperty(o: [*c]c.GObject, id: c.guint, v: [*c]const c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(o));
    switch (id) {
        1 => s.stream_id = c.g_value_get_uint(v),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn getProperty(o: [*c]c.GObject, id: c.guint, v: [*c]c.GValue, spec: [*c]c.GParamSpec) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(o));
    switch (id) {
        1 => c.g_value_set_uint(v, s.stream_id),
        else => common.warnInvalid(o, id, spec, FILE, 0),
    }
}

fn classInit(k: c.gpointer, _: c.gpointer) callconv(.c) void {
    const gc: *c.GObjectClass = @ptrCast(@alignCast(k));
    gc.set_property = setProperty;
    gc.get_property = getProperty;
    c.g_object_class_install_property(gc, 1, c.g_param_spec_uint("stream-id", "ICE stream id", "ICE stream id associated with this stream", 0, std.math.maxInt(c.guint), 0, c.G_PARAM_READWRITE | c.G_PARAM_CONSTRUCT_ONLY | c.G_PARAM_STATIC_STRINGS));
}

pub export fn gst_webrtc_ice_stream_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.object(c.gst_object_get_type, "GstWebRTCICEStream", Class, Stream, classInit, null, c.G_TYPE_FLAG_ABSTRACT);
            common.category("webrtcicestream");
            return t;
        }
    }.f);
}
