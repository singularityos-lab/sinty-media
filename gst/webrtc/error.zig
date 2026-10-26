const c = @import("../c.zig").c;

comptime {
    @import("../abi.zig").check(@This());
}

pub export fn gst_webrtc_error_quark() c.GQuark {
    return c.g_quark_from_static_string("gst-webrtc-error-quark");
}
