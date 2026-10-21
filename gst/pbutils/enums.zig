const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

comptime {
    @import("../abi.zig").check(@This());
}

var gst_install_plugins_return_once: gtype.Once = .{};
var gst_discoverer_result_once: gtype.Once = .{};
var gst_discoverer_serialize_flags_once: gtype.Once = .{};
var gst_pb_utils_caps_description_flags_once: gtype.Once = .{};
var gst_audio_visualizer_shader_once: gtype.Once = .{};

pub export fn gst_install_plugins_return_get_type() c.GType {
    return gst_install_plugins_return_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_INSTALL_PLUGINS_SUCCESS, .value_name = "GST_INSTALL_PLUGINS_SUCCESS", .value_nick = "success" },
            .{ .value = c.GST_INSTALL_PLUGINS_NOT_FOUND, .value_name = "GST_INSTALL_PLUGINS_NOT_FOUND", .value_nick = "not-found" },
            .{ .value = c.GST_INSTALL_PLUGINS_ERROR, .value_name = "GST_INSTALL_PLUGINS_ERROR", .value_nick = "error" },
            .{ .value = c.GST_INSTALL_PLUGINS_PARTIAL_SUCCESS, .value_name = "GST_INSTALL_PLUGINS_PARTIAL_SUCCESS", .value_nick = "partial-success" },
            .{ .value = c.GST_INSTALL_PLUGINS_USER_ABORT, .value_name = "GST_INSTALL_PLUGINS_USER_ABORT", .value_nick = "user-abort" },
            .{ .value = c.GST_INSTALL_PLUGINS_CRASHED, .value_name = "GST_INSTALL_PLUGINS_CRASHED", .value_nick = "crashed" },
            .{ .value = c.GST_INSTALL_PLUGINS_INVALID, .value_name = "GST_INSTALL_PLUGINS_INVALID", .value_nick = "invalid" },
            .{ .value = c.GST_INSTALL_PLUGINS_STARTED_OK, .value_name = "GST_INSTALL_PLUGINS_STARTED_OK", .value_nick = "started-ok" },
            .{ .value = c.GST_INSTALL_PLUGINS_INTERNAL_FAILURE, .value_name = "GST_INSTALL_PLUGINS_INTERNAL_FAILURE", .value_nick = "internal-failure" },
            .{ .value = c.GST_INSTALL_PLUGINS_HELPER_MISSING, .value_name = "GST_INSTALL_PLUGINS_HELPER_MISSING", .value_nick = "helper-missing" },
            .{ .value = c.GST_INSTALL_PLUGINS_INSTALL_IN_PROGRESS, .value_name = "GST_INSTALL_PLUGINS_INSTALL_IN_PROGRESS", .value_nick = "install-in-progress" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstInstallPluginsReturn"), &values);
        }
    }.f);
}

pub export fn gst_discoverer_result_get_type() c.GType {
    return gst_discoverer_result_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_DISCOVERER_OK, .value_name = "GST_DISCOVERER_OK", .value_nick = "ok" },
            .{ .value = c.GST_DISCOVERER_URI_INVALID, .value_name = "GST_DISCOVERER_URI_INVALID", .value_nick = "uri-invalid" },
            .{ .value = c.GST_DISCOVERER_ERROR, .value_name = "GST_DISCOVERER_ERROR", .value_nick = "error" },
            .{ .value = c.GST_DISCOVERER_TIMEOUT, .value_name = "GST_DISCOVERER_TIMEOUT", .value_nick = "timeout" },
            .{ .value = c.GST_DISCOVERER_BUSY, .value_name = "GST_DISCOVERER_BUSY", .value_nick = "busy" },
            .{ .value = c.GST_DISCOVERER_MISSING_PLUGINS, .value_name = "GST_DISCOVERER_MISSING_PLUGINS", .value_nick = "missing-plugins" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstDiscovererResult"), &values);
        }
    }.f);
}

pub export fn gst_discoverer_serialize_flags_get_type() c.GType {
    return gst_discoverer_serialize_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = c.GST_DISCOVERER_SERIALIZE_BASIC, .value_name = "GST_DISCOVERER_SERIALIZE_BASIC", .value_nick = "basic" },
            .{ .value = c.GST_DISCOVERER_SERIALIZE_CAPS, .value_name = "GST_DISCOVERER_SERIALIZE_CAPS", .value_nick = "caps" },
            .{ .value = c.GST_DISCOVERER_SERIALIZE_TAGS, .value_name = "GST_DISCOVERER_SERIALIZE_TAGS", .value_nick = "tags" },
            .{ .value = c.GST_DISCOVERER_SERIALIZE_MISC, .value_name = "GST_DISCOVERER_SERIALIZE_MISC", .value_nick = "misc" },
            .{ .value = c.GST_DISCOVERER_SERIALIZE_ALL, .value_name = "GST_DISCOVERER_SERIALIZE_ALL", .value_nick = "all" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstDiscovererSerializeFlags"), &values);
        }
    }.f);
}

pub export fn gst_pb_utils_caps_description_flags_get_type() c.GType {
    return gst_pb_utils_caps_description_flags_once.get(struct {
        var values = [_]c.GFlagsValue{
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_CONTAINER, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_CONTAINER", .value_nick = "container" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_AUDIO, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_AUDIO", .value_nick = "audio" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_VIDEO, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_VIDEO", .value_nick = "video" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_IMAGE, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_IMAGE", .value_nick = "image" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_SUBTITLE, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_SUBTITLE", .value_nick = "subtitle" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_TAG, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_TAG", .value_nick = "tag" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_GENERIC, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_GENERIC", .value_nick = "generic" },
            .{ .value = c.GST_PBUTILS_CAPS_DESCRIPTION_FLAG_METADATA, .value_name = "GST_PBUTILS_CAPS_DESCRIPTION_FLAG_METADATA", .value_nick = "metadata" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_flags_register_static(c.g_intern_static_string("GstPbUtilsCapsDescriptionFlags"), &values);
        }
    }.f);
}

pub export fn gst_audio_visualizer_shader_get_type() c.GType {
    return gst_audio_visualizer_shader_once.get(struct {
        var values = [_]c.GEnumValue{
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_NONE, .value_name = "GST_AUDIO_VISUALIZER_SHADER_NONE", .value_nick = "none" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE", .value_nick = "fade" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_UP, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_UP", .value_nick = "fade-and-move-up" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_DOWN, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_DOWN", .value_nick = "fade-and-move-down" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_LEFT, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_LEFT", .value_nick = "fade-and-move-left" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_RIGHT, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_RIGHT", .value_nick = "fade-and-move-right" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_OUT, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_OUT", .value_nick = "fade-and-move-horiz-out" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_IN, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_HORIZ_IN", .value_nick = "fade-and-move-horiz-in" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_OUT, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_OUT", .value_nick = "fade-and-move-vert-out" },
            .{ .value = c.GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_IN, .value_name = "GST_AUDIO_VISUALIZER_SHADER_FADE_AND_MOVE_VERT_IN", .value_nick = "fade-and-move-vert-in" },
            .{ .value = 0, .value_name = null, .value_nick = null },
        };
        fn f() c.GType {
            return c.g_enum_register_static(c.g_intern_static_string("GstAudioVisualizerShader"), &values);
        }
    }.f);
}
