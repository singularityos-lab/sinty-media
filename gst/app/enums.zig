const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var stream_once: gtype.Once = .{};
var leaky_once: gtype.Once = .{};

pub export fn gst_app_stream_type_get_type() c.GType {
    return stream_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_APP_STREAM_TYPE_STREAM, .value_name = "GST_APP_STREAM_TYPE_STREAM", .value_nick = "stream" },
            .{ .value = c.GST_APP_STREAM_TYPE_SEEKABLE, .value_name = "GST_APP_STREAM_TYPE_SEEKABLE", .value_nick = "seekable" },
            .{ .value = c.GST_APP_STREAM_TYPE_RANDOM_ACCESS, .value_name = "GST_APP_STREAM_TYPE_RANDOM_ACCESS", .value_nick = "random-access" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstAppStreamType"), &values);
        }
    }.f);
}

pub export fn gst_app_leaky_type_get_type() c.GType {
    return leaky_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_APP_LEAKY_TYPE_NONE, .value_name = "GST_APP_LEAKY_TYPE_NONE", .value_nick = "none" },
            .{ .value = c.GST_APP_LEAKY_TYPE_UPSTREAM, .value_name = "GST_APP_LEAKY_TYPE_UPSTREAM", .value_nick = "upstream" },
            .{ .value = c.GST_APP_LEAKY_TYPE_DOWNSTREAM, .value_name = "GST_APP_LEAKY_TYPE_DOWNSTREAM", .value_nick = "downstream" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstAppLeakyType"), &values);
        }
    }.f);
}
