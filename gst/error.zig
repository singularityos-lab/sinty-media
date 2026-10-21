const std = @import("std");
const c = @import("c.zig").c;
const errdefs = @import("errdefs.zig");

comptime {
    @import("abi.zig").check(@This());
}

fn Quark(comptime name: [:0]const u8) type {
    return struct {
        var q: c.GQuark = 0;
        fn get() c.GQuark {
            if (q == 0) q = c.g_quark_from_static_string(name.ptr);
            return q;
        }
    };
}

const Core = Quark("gst-core-error-quark");
const Library = Quark("gst-library-error-quark");
const Resource = Quark("gst-resource-error-quark");
const Stream = Quark("gst-stream-error-quark");

pub export fn gst_core_error_quark() c.GQuark {
    return Core.get();
}
pub export fn gst_library_error_quark() c.GQuark {
    return Library.get();
}
pub export fn gst_resource_error_quark() c.GQuark {
    return Resource.get();
}
pub export fn gst_stream_error_quark() c.GQuark {
    return Stream.get();
}

fn standard(domain: []const u8, code: c.gint) ?[*c]const u8 {
    for (errdefs.entries) |e| {
        if (e.code == code and std.mem.eql(u8, e.domain, domain)) return if (e.text) |t| t.ptr else null;
    }
    return null;
}

pub export fn gst_error_get_message(domain: c.GQuark, code: c.gint) [*c]u8 {
    const name: []const u8 = if (domain == Core.get()) "core" else if (domain == Library.get()) "library" else if (domain == Resource.get()) "resource" else if (domain == Stream.get()) "stream" else {
        c.g_log("GStreamer", c.G_LOG_LEVEL_WARNING, "No error messages for domain %s", c.g_quark_to_string(domain));
        return c.g_strdup_printf(c.g_dgettext("gstreamer-1.0", "No error message for domain %s."), c.g_quark_to_string(domain));
    };
    if (standard(name, code)) |text| return c.g_strdup(c.g_dgettext("gstreamer-1.0", text));
    return c.g_strdup_printf(c.g_dgettext("gstreamer-1.0", "No standard error message for domain %s and code %d."), c.g_quark_to_string(domain), code);
}
