const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");
const common = @import("common.zig");

comptime {
    @import("../abi.zig").check(@This());
}

const Desc = c.GstWebRTCSessionDescription;

var once: gtype.Once = .{};

pub export fn gst_webrtc_sdp_type_to_string(t: c.GstWebRTCSDPType) [*c]const u8 {
    return switch (t) {
        c.GST_WEBRTC_SDP_TYPE_OFFER => "offer",
        c.GST_WEBRTC_SDP_TYPE_PRANSWER => "pranswer",
        c.GST_WEBRTC_SDP_TYPE_ANSWER => "answer",
        c.GST_WEBRTC_SDP_TYPE_ROLLBACK => "rollback",
        else => "unknown",
    };
}

pub export fn gst_webrtc_session_description_new(t: c.GstWebRTCSDPType, sdp: [*c]c.GstSDPMessage) [*c]Desc {
    const d: *Desc = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Desc))));
    d.type = t;
    d.sdp = sdp;
    return d;
}

pub export fn gst_webrtc_session_description_copy(src: [*c]const Desc) [*c]Desc {
    if (src == null) return null;
    const d: *Desc = @ptrCast(@alignCast(c.g_malloc0(@sizeOf(Desc))));
    d.type = src.*.type;
    if (src.*.sdp != null) _ = c.gst_sdp_message_copy(src.*.sdp, &d.sdp);
    return d;
}

pub export fn gst_webrtc_session_description_free(desc: [*c]Desc) void {
    if (!common.that(desc != null, "gst_webrtc_session_description_free", "desc != NULL")) return;
    if (desc.*.sdp != null) _ = c.gst_sdp_message_free(desc.*.sdp);
    c.g_free(desc);
}

pub export fn gst_webrtc_session_description_get_type() c.GType {
    return once.get(struct {
        fn f() c.GType {
            const t = gtype.boxed("GstWebRTCSessionDescription", @ptrCast(&gst_webrtc_session_description_copy), @ptrCast(&gst_webrtc_session_description_free));
            common.category("webrtcsessiondescription");
            return t;
        }
    }.f);
}
