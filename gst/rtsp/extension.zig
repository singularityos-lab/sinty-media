const std = @import("std");
const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const enums = @import("enums.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Ext = c.GstRTSPExtension;
const Iface = c.GstRTSPExtensionInterface;
const Msg = c.GstRTSPMessage;

var once: gtype.Once = .{};
var sig_send: c.guint = 0;
var made = false;

pub export fn gst_rtsp_extension_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const info = std.mem.zeroInit(c.GTypeInfo, .{ .class_size = @sizeOf(Iface), .base_init = baseInit });
            return c.g_type_register_static(@as(c.GType, 2 << c.G_TYPE_FUNDAMENTAL_SHIFT), "GstRTSPExtension", &info, 0);
        }
    }.f);
}

fn baseInit(k: c.gpointer) callconv(.c) void {
    if (made) return;
    const t = @as(*c.GTypeInterface, @ptrCast(@alignCast(k))).g_type;
    sig_send = c.g_signal_new("send", t, c.G_SIGNAL_RUN_LAST, @offsetOf(Iface, "send"), null, null, null, enums.gst_rtsp_result_get_type(), @as(c.guint, 2), @as(c.GType, c.G_TYPE_POINTER), @as(c.GType, c.G_TYPE_POINTER));
    made = true;
}

fn iface(e: anytype) *Iface {
    const inst: *c.GTypeInstance = @ptrCast(@alignCast(e));
    return @ptrCast(@alignCast(c.g_type_interface_peek(inst.g_class, gst_rtsp_extension_get_type())));
}

pub export fn gst_rtsp_extension_detect_server(e: ?*Ext, resp: [*c]Msg) c.gboolean {
    return if (iface(e).detect_server) |f| f(e, resp) else 1;
}

pub export fn gst_rtsp_extension_before_send(e: ?*Ext, req: [*c]Msg) c.GstRTSPResult {
    return if (iface(e).before_send) |f| f(e, req) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_after_send(e: ?*Ext, req: [*c]Msg, resp: [*c]Msg) c.GstRTSPResult {
    return if (iface(e).after_send) |f| f(e, req, resp) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_parse_sdp(e: ?*Ext, sdp: [*c]c.GstSDPMessage, s: ?*c.GstStructure) c.GstRTSPResult {
    return if (iface(e).parse_sdp) |f| f(e, sdp, s) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_setup_media(e: ?*Ext, media: [*c]c.GstSDPMedia) c.GstRTSPResult {
    return if (iface(e).setup_media) |f| f(e, media) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_configure_stream(e: ?*Ext, caps: [*c]c.GstCaps) c.gboolean {
    return if (iface(e).configure_stream) |f| f(e, caps) else 1;
}

pub export fn gst_rtsp_extension_get_transports(e: ?*Ext, protocols: c.GstRTSPLowerTrans, transport: [*c][*c]u8) c.GstRTSPResult {
    return if (iface(e).get_transports) |f| f(e, protocols, transport) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_stream_select(e: ?*Ext, url: [*c]c.GstRTSPUrl) c.GstRTSPResult {
    return if (iface(e).stream_select) |f| f(e, url) else c.GST_RTSP_OK;
}

pub export fn gst_rtsp_extension_receive_request(e: ?*Ext, req: [*c]Msg) c.GstRTSPResult {
    return if (iface(e).receive_request) |f| f(e, req) else c.GST_RTSP_ENOTIMPL;
}

pub export fn gst_rtsp_extension_send(e: ?*Ext, req: [*c]Msg, resp: [*c]Msg) c.GstRTSPResult {
    var res: c.GstRTSPResult = c.GST_RTSP_OK;
    c.g_signal_emit(e, sig_send, 0, req, resp, &res);
    return res;
}
