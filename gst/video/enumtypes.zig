const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

var gst_color_balance_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_COLOR_BALANCE_HARDWARE", .value_nick = "hardware" },
    .{ .value = 1, .value_name = "GST_COLOR_BALANCE_SOFTWARE", .value_nick = "software" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_color_balance_type_once: gtype.Once = .{};
fn gst_color_balance_type_register() c.GType {
    return c.g_enum_register_static("GstColorBalanceType", &gst_color_balance_type_values);
}
pub export fn gst_color_balance_type_get_type() c.GType {
    return gst_color_balance_type_once.get(gst_color_balance_type_register);
}

var gst_video_decoder_request_sync_point_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_VIDEO_DECODER_REQUEST_SYNC_POINT_DISCARD_INPUT", .value_nick = "discard-input" },
    .{ .value = 2, .value_name = "GST_VIDEO_DECODER_REQUEST_SYNC_POINT_CORRUPT_OUTPUT", .value_nick = "corrupt-output" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_decoder_request_sync_point_flags_once: gtype.Once = .{};
fn gst_video_decoder_request_sync_point_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoDecoderRequestSyncPointFlags", &gst_video_decoder_request_sync_point_flags_values);
}
pub export fn gst_video_decoder_request_sync_point_flags_get_type() c.GType {
    return gst_video_decoder_request_sync_point_flags_once.get(gst_video_decoder_request_sync_point_flags_register);
}

var gst_video_gl_texture_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_LUMINANCE", .value_nick = "luminance" },
    .{ .value = 1, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_LUMINANCE_ALPHA", .value_nick = "luminance-alpha" },
    .{ .value = 2, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_RGB16", .value_nick = "rgb16" },
    .{ .value = 3, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_RGB", .value_nick = "rgb" },
    .{ .value = 4, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_RGBA", .value_nick = "rgba" },
    .{ .value = 5, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_R", .value_nick = "r" },
    .{ .value = 6, .value_name = "GST_VIDEO_GL_TEXTURE_TYPE_RG", .value_nick = "rg" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_gl_texture_type_once: gtype.Once = .{};
fn gst_video_gl_texture_type_register() c.GType {
    return c.g_enum_register_static("GstVideoGLTextureType", &gst_video_gl_texture_type_values);
}
pub export fn gst_video_gl_texture_type_get_type() c.GType {
    return gst_video_gl_texture_type_once.get(gst_video_gl_texture_type_register);
}

var gst_video_gl_texture_orientation_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_GL_TEXTURE_ORIENTATION_X_NORMAL_Y_NORMAL", .value_nick = "normal-y-normal" },
    .{ .value = 1, .value_name = "GST_VIDEO_GL_TEXTURE_ORIENTATION_X_NORMAL_Y_FLIP", .value_nick = "normal-y-flip" },
    .{ .value = 2, .value_name = "GST_VIDEO_GL_TEXTURE_ORIENTATION_X_FLIP_Y_NORMAL", .value_nick = "flip-y-normal" },
    .{ .value = 3, .value_name = "GST_VIDEO_GL_TEXTURE_ORIENTATION_X_FLIP_Y_FLIP", .value_nick = "flip-y-flip" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_gl_texture_orientation_once: gtype.Once = .{};
fn gst_video_gl_texture_orientation_register() c.GType {
    return c.g_enum_register_static("GstVideoGLTextureOrientation", &gst_video_gl_texture_orientation_values);
}
pub export fn gst_video_gl_texture_orientation_get_type() c.GType {
    return gst_video_gl_texture_orientation_once.get(gst_video_gl_texture_orientation_register);
}

var gst_video_time_code_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_TIME_CODE_FLAGS_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_TIME_CODE_FLAGS_DROP_FRAME", .value_nick = "drop-frame" },
    .{ .value = 2, .value_name = "GST_VIDEO_TIME_CODE_FLAGS_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_time_code_flags_once: gtype.Once = .{};
fn gst_video_time_code_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoTimeCodeFlags", &gst_video_time_code_flags_values);
}
pub export fn gst_video_time_code_flags_get_type() c.GType {
    return gst_video_time_code_flags_once.get(gst_video_time_code_flags_register);
}

var gst_video_codec_frame_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_VIDEO_CODEC_FRAME_FLAG_DECODE_ONLY", .value_nick = "decode-only" },
    .{ .value = 2, .value_name = "GST_VIDEO_CODEC_FRAME_FLAG_SYNC_POINT", .value_nick = "sync-point" },
    .{ .value = 4, .value_name = "GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME", .value_nick = "force-keyframe" },
    .{ .value = 8, .value_name = "GST_VIDEO_CODEC_FRAME_FLAG_FORCE_KEYFRAME_HEADERS", .value_nick = "force-keyframe-headers" },
    .{ .value = 16, .value_name = "GST_VIDEO_CODEC_FRAME_FLAG_CORRUPTED", .value_nick = "corrupted" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_codec_frame_flags_once: gtype.Once = .{};
fn gst_video_codec_frame_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoCodecFrameFlags", &gst_video_codec_frame_flags_values);
}
pub export fn gst_video_codec_frame_flags_get_type() c.GType {
    return gst_video_codec_frame_flags_once.get(gst_video_codec_frame_flags_register);
}

var gst_navigation_modifier_type_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_NAVIGATION_MODIFIER_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_NAVIGATION_MODIFIER_SHIFT_MASK", .value_nick = "shift-mask" },
    .{ .value = 2, .value_name = "GST_NAVIGATION_MODIFIER_LOCK_MASK", .value_nick = "lock-mask" },
    .{ .value = 4, .value_name = "GST_NAVIGATION_MODIFIER_CONTROL_MASK", .value_nick = "control-mask" },
    .{ .value = 8, .value_name = "GST_NAVIGATION_MODIFIER_MOD1_MASK", .value_nick = "mod1-mask" },
    .{ .value = 16, .value_name = "GST_NAVIGATION_MODIFIER_MOD2_MASK", .value_nick = "mod2-mask" },
    .{ .value = 32, .value_name = "GST_NAVIGATION_MODIFIER_MOD3_MASK", .value_nick = "mod3-mask" },
    .{ .value = 64, .value_name = "GST_NAVIGATION_MODIFIER_MOD4_MASK", .value_nick = "mod4-mask" },
    .{ .value = 128, .value_name = "GST_NAVIGATION_MODIFIER_MOD5_MASK", .value_nick = "mod5-mask" },
    .{ .value = 256, .value_name = "GST_NAVIGATION_MODIFIER_BUTTON1_MASK", .value_nick = "button1-mask" },
    .{ .value = 512, .value_name = "GST_NAVIGATION_MODIFIER_BUTTON2_MASK", .value_nick = "button2-mask" },
    .{ .value = 1024, .value_name = "GST_NAVIGATION_MODIFIER_BUTTON3_MASK", .value_nick = "button3-mask" },
    .{ .value = 2048, .value_name = "GST_NAVIGATION_MODIFIER_BUTTON4_MASK", .value_nick = "button4-mask" },
    .{ .value = 4096, .value_name = "GST_NAVIGATION_MODIFIER_BUTTON5_MASK", .value_nick = "button5-mask" },
    .{ .value = 67108864, .value_name = "GST_NAVIGATION_MODIFIER_SUPER_MASK", .value_nick = "super-mask" },
    .{ .value = 134217728, .value_name = "GST_NAVIGATION_MODIFIER_HYPER_MASK", .value_nick = "hyper-mask" },
    .{ .value = 268435456, .value_name = "GST_NAVIGATION_MODIFIER_META_MASK", .value_nick = "meta-mask" },
    .{ .value = 469770239, .value_name = "GST_NAVIGATION_MODIFIER_MASK", .value_nick = "mask" },
    .{ .value = 268435456, .value_name = "GST_NAVIGATION_MODIFIER_META_MASK", .value_nick = "meta-mask" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_navigation_modifier_type_once: gtype.Once = .{};
fn gst_navigation_modifier_type_register() c.GType {
    return c.g_flags_register_static("GstNavigationModifierType", &gst_navigation_modifier_type_values);
}
pub export fn gst_navigation_modifier_type_get_type() c.GType {
    return gst_navigation_modifier_type_once.get(gst_navigation_modifier_type_register);
}

var gst_navigation_command_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_NAVIGATION_COMMAND_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_NAVIGATION_COMMAND_MENU1", .value_nick = "menu1" },
    .{ .value = 2, .value_name = "GST_NAVIGATION_COMMAND_MENU2", .value_nick = "menu2" },
    .{ .value = 3, .value_name = "GST_NAVIGATION_COMMAND_MENU3", .value_nick = "menu3" },
    .{ .value = 4, .value_name = "GST_NAVIGATION_COMMAND_MENU4", .value_nick = "menu4" },
    .{ .value = 5, .value_name = "GST_NAVIGATION_COMMAND_MENU5", .value_nick = "menu5" },
    .{ .value = 6, .value_name = "GST_NAVIGATION_COMMAND_MENU6", .value_nick = "menu6" },
    .{ .value = 7, .value_name = "GST_NAVIGATION_COMMAND_MENU7", .value_nick = "menu7" },
    .{ .value = 20, .value_name = "GST_NAVIGATION_COMMAND_LEFT", .value_nick = "left" },
    .{ .value = 21, .value_name = "GST_NAVIGATION_COMMAND_RIGHT", .value_nick = "right" },
    .{ .value = 22, .value_name = "GST_NAVIGATION_COMMAND_UP", .value_nick = "up" },
    .{ .value = 23, .value_name = "GST_NAVIGATION_COMMAND_DOWN", .value_nick = "down" },
    .{ .value = 24, .value_name = "GST_NAVIGATION_COMMAND_ACTIVATE", .value_nick = "activate" },
    .{ .value = 30, .value_name = "GST_NAVIGATION_COMMAND_PREV_ANGLE", .value_nick = "prev-angle" },
    .{ .value = 31, .value_name = "GST_NAVIGATION_COMMAND_NEXT_ANGLE", .value_nick = "next-angle" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_navigation_command_once: gtype.Once = .{};
fn gst_navigation_command_register() c.GType {
    return c.g_enum_register_static("GstNavigationCommand", &gst_navigation_command_values);
}
pub export fn gst_navigation_command_get_type() c.GType {
    return gst_navigation_command_once.get(gst_navigation_command_register);
}

var gst_navigation_query_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_NAVIGATION_QUERY_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_NAVIGATION_QUERY_COMMANDS", .value_nick = "commands" },
    .{ .value = 2, .value_name = "GST_NAVIGATION_QUERY_ANGLES", .value_nick = "angles" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_navigation_query_type_once: gtype.Once = .{};
fn gst_navigation_query_type_register() c.GType {
    return c.g_enum_register_static("GstNavigationQueryType", &gst_navigation_query_type_values);
}
pub export fn gst_navigation_query_type_get_type() c.GType {
    return gst_navigation_query_type_once.get(gst_navigation_query_type_register);
}

var gst_navigation_message_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_NAVIGATION_MESSAGE_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_NAVIGATION_MESSAGE_MOUSE_OVER", .value_nick = "mouse-over" },
    .{ .value = 2, .value_name = "GST_NAVIGATION_MESSAGE_COMMANDS_CHANGED", .value_nick = "commands-changed" },
    .{ .value = 3, .value_name = "GST_NAVIGATION_MESSAGE_ANGLES_CHANGED", .value_nick = "angles-changed" },
    .{ .value = 4, .value_name = "GST_NAVIGATION_MESSAGE_EVENT", .value_nick = "event" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_navigation_message_type_once: gtype.Once = .{};
fn gst_navigation_message_type_register() c.GType {
    return c.g_enum_register_static("GstNavigationMessageType", &gst_navigation_message_type_values);
}
pub export fn gst_navigation_message_type_get_type() c.GType {
    return gst_navigation_message_type_once.get(gst_navigation_message_type_register);
}

var gst_navigation_event_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_NAVIGATION_EVENT_INVALID", .value_nick = "invalid" },
    .{ .value = 1, .value_name = "GST_NAVIGATION_EVENT_KEY_PRESS", .value_nick = "key-press" },
    .{ .value = 2, .value_name = "GST_NAVIGATION_EVENT_KEY_RELEASE", .value_nick = "key-release" },
    .{ .value = 3, .value_name = "GST_NAVIGATION_EVENT_MOUSE_BUTTON_PRESS", .value_nick = "mouse-button-press" },
    .{ .value = 4, .value_name = "GST_NAVIGATION_EVENT_MOUSE_BUTTON_RELEASE", .value_nick = "mouse-button-release" },
    .{ .value = 5, .value_name = "GST_NAVIGATION_EVENT_MOUSE_MOVE", .value_nick = "mouse-move" },
    .{ .value = 6, .value_name = "GST_NAVIGATION_EVENT_COMMAND", .value_nick = "command" },
    .{ .value = 7, .value_name = "GST_NAVIGATION_EVENT_MOUSE_SCROLL", .value_nick = "mouse-scroll" },
    .{ .value = 8, .value_name = "GST_NAVIGATION_EVENT_TOUCH_DOWN", .value_nick = "touch-down" },
    .{ .value = 9, .value_name = "GST_NAVIGATION_EVENT_TOUCH_MOTION", .value_nick = "touch-motion" },
    .{ .value = 10, .value_name = "GST_NAVIGATION_EVENT_TOUCH_UP", .value_nick = "touch-up" },
    .{ .value = 11, .value_name = "GST_NAVIGATION_EVENT_TOUCH_FRAME", .value_nick = "touch-frame" },
    .{ .value = 12, .value_name = "GST_NAVIGATION_EVENT_TOUCH_CANCEL", .value_nick = "touch-cancel" },
    .{ .value = 13, .value_name = "GST_NAVIGATION_EVENT_MOUSE_DOUBLE_CLICK", .value_nick = "mouse-double-click" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_navigation_event_type_once: gtype.Once = .{};
fn gst_navigation_event_type_register() c.GType {
    return c.g_enum_register_static("GstNavigationEventType", &gst_navigation_event_type_values);
}
pub export fn gst_navigation_event_type_get_type() c.GType {
    return gst_navigation_event_type_once.get(gst_navigation_event_type_register);
}

var gst_video_ancillary_did_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_ANCILLARY_DID_UNDEFINED", .value_nick = "undefined" },
    .{ .value = 128, .value_name = "GST_VIDEO_ANCILLARY_DID_DELETION", .value_nick = "deletion" },
    .{ .value = 160, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_3G_AUDIO_DATA_FIRST", .value_nick = "hanc-3g-audio-data-first" },
    .{ .value = 167, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_3G_AUDIO_DATA_LAST", .value_nick = "hanc-3g-audio-data-last" },
    .{ .value = 224, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_HDTV_AUDIO_DATA_FIRST", .value_nick = "hanc-hdtv-audio-data-first" },
    .{ .value = 231, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_HDTV_AUDIO_DATA_LAST", .value_nick = "hanc-hdtv-audio-data-last" },
    .{ .value = 236, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_SDTV_AUDIO_DATA_1_FIRST", .value_nick = "hanc-sdtv-audio-data-1-first" },
    .{ .value = 239, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_SDTV_AUDIO_DATA_1_LAST", .value_nick = "hanc-sdtv-audio-data-1-last" },
    .{ .value = 240, .value_name = "GST_VIDEO_ANCILLARY_DID_CAMERA_POSITION", .value_nick = "camera-position" },
    .{ .value = 244, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_ERROR_DETECTION", .value_nick = "hanc-error-detection" },
    .{ .value = 248, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_SDTV_AUDIO_DATA_2_FIRST", .value_nick = "hanc-sdtv-audio-data-2-first" },
    .{ .value = 255, .value_name = "GST_VIDEO_ANCILLARY_DID_HANC_SDTV_AUDIO_DATA_2_LAST", .value_nick = "hanc-sdtv-audio-data-2-last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_ancillary_did_once: gtype.Once = .{};
fn gst_video_ancillary_did_register() c.GType {
    return c.g_enum_register_static("GstVideoAncillaryDID", &gst_video_ancillary_did_values);
}
pub export fn gst_video_ancillary_did_get_type() c.GType {
    return gst_video_ancillary_did_once.get(gst_video_ancillary_did_register);
}

var gst_video_ancillary_di_d16_values = [_]c.GEnumValue{
    .{ .value = 24833, .value_name = "GST_VIDEO_ANCILLARY_DID16_S334_EIA_708", .value_nick = "s334-eia-708" },
    .{ .value = 24834, .value_name = "GST_VIDEO_ANCILLARY_DID16_S334_EIA_608", .value_nick = "s334-eia-608" },
    .{ .value = 16645, .value_name = "GST_VIDEO_ANCILLARY_DID16_S2016_3_AFD_BAR", .value_nick = "s2016-3-afd-bar" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_ancillary_di_d16_once: gtype.Once = .{};
fn gst_video_ancillary_di_d16_register() c.GType {
    return c.g_enum_register_static("GstVideoAncillaryDID16", &gst_video_ancillary_di_d16_values);
}
pub export fn gst_video_ancillary_di_d16_get_type() c.GType {
    return gst_video_ancillary_di_d16_once.get(gst_video_ancillary_di_d16_register);
}

var gst_ancillary_meta_field_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_ANCILLARY_META_FIELD_PROGRESSIVE", .value_nick = "progressive" },
    .{ .value = 16, .value_name = "GST_ANCILLARY_META_FIELD_INTERLACED_FIRST", .value_nick = "interlaced-first" },
    .{ .value = 17, .value_name = "GST_ANCILLARY_META_FIELD_INTERLACED_SECOND", .value_nick = "interlaced-second" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_ancillary_meta_field_once: gtype.Once = .{};
fn gst_ancillary_meta_field_register() c.GType {
    return c.g_enum_register_static("GstAncillaryMetaField", &gst_ancillary_meta_field_values);
}
pub export fn gst_ancillary_meta_field_get_type() c.GType {
    return gst_ancillary_meta_field_once.get(gst_ancillary_meta_field_register);
}

var gst_video_afd_value_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_AFD_UNAVAILABLE", .value_nick = "unavailable" },
    .{ .value = 2, .value_name = "GST_VIDEO_AFD_16_9_TOP_ALIGNED", .value_nick = "16-9-top-aligned" },
    .{ .value = 3, .value_name = "GST_VIDEO_AFD_14_9_TOP_ALIGNED", .value_nick = "14-9-top-aligned" },
    .{ .value = 4, .value_name = "GST_VIDEO_AFD_GREATER_THAN_16_9", .value_nick = "greater-than-16-9" },
    .{ .value = 8, .value_name = "GST_VIDEO_AFD_4_3_FULL_16_9_FULL", .value_nick = "4-3-full-16-9-full" },
    .{ .value = 9, .value_name = "GST_VIDEO_AFD_4_3_FULL_4_3_PILLAR", .value_nick = "4-3-full-4-3-pillar" },
    .{ .value = 10, .value_name = "GST_VIDEO_AFD_16_9_LETTER_16_9_FULL", .value_nick = "16-9-letter-16-9-full" },
    .{ .value = 11, .value_name = "GST_VIDEO_AFD_14_9_LETTER_14_9_PILLAR", .value_nick = "14-9-letter-14-9-pillar" },
    .{ .value = 13, .value_name = "GST_VIDEO_AFD_4_3_FULL_14_9_CENTER", .value_nick = "4-3-full-14-9-center" },
    .{ .value = 14, .value_name = "GST_VIDEO_AFD_16_9_LETTER_14_9_CENTER", .value_nick = "16-9-letter-14-9-center" },
    .{ .value = 15, .value_name = "GST_VIDEO_AFD_16_9_LETTER_4_3_CENTER", .value_nick = "16-9-letter-4-3-center" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_afd_value_once: gtype.Once = .{};
fn gst_video_afd_value_register() c.GType {
    return c.g_enum_register_static("GstVideoAFDValue", &gst_video_afd_value_values);
}
pub export fn gst_video_afd_value_get_type() c.GType {
    return gst_video_afd_value_once.get(gst_video_afd_value_register);
}

var gst_video_afd_spec_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_AFD_SPEC_DVB_ETSI", .value_nick = "dvb-etsi" },
    .{ .value = 1, .value_name = "GST_VIDEO_AFD_SPEC_ATSC_A53", .value_nick = "atsc-a53" },
    .{ .value = 2, .value_name = "GST_VIDEO_AFD_SPEC_SMPTE_ST2016_1", .value_nick = "smpte-st2016-1" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_afd_spec_once: gtype.Once = .{};
fn gst_video_afd_spec_register() c.GType {
    return c.g_enum_register_static("GstVideoAFDSpec", &gst_video_afd_spec_values);
}
pub export fn gst_video_afd_spec_get_type() c.GType {
    return gst_video_afd_spec_once.get(gst_video_afd_spec_register);
}

var gst_video_caption_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_CAPTION_TYPE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_CAPTION_TYPE_CEA608_RAW", .value_nick = "cea608-raw" },
    .{ .value = 2, .value_name = "GST_VIDEO_CAPTION_TYPE_CEA608_S334_1A", .value_nick = "cea608-s334-1a" },
    .{ .value = 3, .value_name = "GST_VIDEO_CAPTION_TYPE_CEA708_RAW", .value_nick = "cea708-raw" },
    .{ .value = 4, .value_name = "GST_VIDEO_CAPTION_TYPE_CEA708_CDP", .value_nick = "cea708-cdp" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_caption_type_once: gtype.Once = .{};
fn gst_video_caption_type_register() c.GType {
    return c.g_enum_register_static("GstVideoCaptionType", &gst_video_caption_type_values);
}
pub export fn gst_video_caption_type_get_type() c.GType {
    return gst_video_caption_type_once.get(gst_video_caption_type_register);
}

var gst_video_vbi_parser_result_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_VBI_PARSER_RESULT_DONE", .value_nick = "done" },
    .{ .value = 1, .value_name = "GST_VIDEO_VBI_PARSER_RESULT_OK", .value_nick = "ok" },
    .{ .value = 2, .value_name = "GST_VIDEO_VBI_PARSER_RESULT_ERROR", .value_nick = "error" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_vbi_parser_result_once: gtype.Once = .{};
fn gst_video_vbi_parser_result_register() c.GType {
    return c.g_enum_register_static("GstVideoVBIParserResult", &gst_video_vbi_parser_result_values);
}
pub export fn gst_video_vbi_parser_result_get_type() c.GType {
    return gst_video_vbi_parser_result_once.get(gst_video_vbi_parser_result_register);
}

var gst_video_chroma_site_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_CHROMA_SITE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_CHROMA_SITE_NONE", .value_nick = "none" },
    .{ .value = 2, .value_name = "GST_VIDEO_CHROMA_SITE_H_COSITED", .value_nick = "h-cosited" },
    .{ .value = 4, .value_name = "GST_VIDEO_CHROMA_SITE_V_COSITED", .value_nick = "v-cosited" },
    .{ .value = 8, .value_name = "GST_VIDEO_CHROMA_SITE_ALT_LINE", .value_nick = "alt-line" },
    .{ .value = 6, .value_name = "GST_VIDEO_CHROMA_SITE_COSITED", .value_nick = "cosited" },
    .{ .value = 1, .value_name = "GST_VIDEO_CHROMA_SITE_JPEG", .value_nick = "jpeg" },
    .{ .value = 2, .value_name = "GST_VIDEO_CHROMA_SITE_MPEG2", .value_nick = "mpeg2" },
    .{ .value = 14, .value_name = "GST_VIDEO_CHROMA_SITE_DV", .value_nick = "dv" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_chroma_site_once: gtype.Once = .{};
fn gst_video_chroma_site_register() c.GType {
    return c.g_flags_register_static("GstVideoChromaSite", &gst_video_chroma_site_values);
}
pub export fn gst_video_chroma_site_get_type() c.GType {
    return gst_video_chroma_site_once.get(gst_video_chroma_site_register);
}

var gst_video_chroma_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_CHROMA_METHOD_NEAREST", .value_nick = "nearest" },
    .{ .value = 1, .value_name = "GST_VIDEO_CHROMA_METHOD_LINEAR", .value_nick = "linear" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_chroma_method_once: gtype.Once = .{};
fn gst_video_chroma_method_register() c.GType {
    return c.g_enum_register_static("GstVideoChromaMethod", &gst_video_chroma_method_values);
}
pub export fn gst_video_chroma_method_get_type() c.GType {
    return gst_video_chroma_method_once.get(gst_video_chroma_method_register);
}

var gst_video_chroma_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_CHROMA_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_CHROMA_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_chroma_flags_once: gtype.Once = .{};
fn gst_video_chroma_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoChromaFlags", &gst_video_chroma_flags_values);
}
pub export fn gst_video_chroma_flags_get_type() c.GType {
    return gst_video_chroma_flags_once.get(gst_video_chroma_flags_register);
}

var gst_video_color_range_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_COLOR_RANGE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_COLOR_RANGE_0_255", .value_nick = "0-255" },
    .{ .value = 2, .value_name = "GST_VIDEO_COLOR_RANGE_16_235", .value_nick = "16-235" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_color_range_once: gtype.Once = .{};
fn gst_video_color_range_register() c.GType {
    return c.g_enum_register_static("GstVideoColorRange", &gst_video_color_range_values);
}
pub export fn gst_video_color_range_get_type() c.GType {
    return gst_video_color_range_once.get(gst_video_color_range_register);
}

var gst_video_color_matrix_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_COLOR_MATRIX_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_COLOR_MATRIX_RGB", .value_nick = "rgb" },
    .{ .value = 2, .value_name = "GST_VIDEO_COLOR_MATRIX_FCC", .value_nick = "fcc" },
    .{ .value = 3, .value_name = "GST_VIDEO_COLOR_MATRIX_BT709", .value_nick = "bt709" },
    .{ .value = 4, .value_name = "GST_VIDEO_COLOR_MATRIX_BT601", .value_nick = "bt601" },
    .{ .value = 5, .value_name = "GST_VIDEO_COLOR_MATRIX_SMPTE240M", .value_nick = "smpte240m" },
    .{ .value = 6, .value_name = "GST_VIDEO_COLOR_MATRIX_BT2020", .value_nick = "bt2020" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_color_matrix_once: gtype.Once = .{};
fn gst_video_color_matrix_register() c.GType {
    return c.g_enum_register_static("GstVideoColorMatrix", &gst_video_color_matrix_values);
}
pub export fn gst_video_color_matrix_get_type() c.GType {
    return gst_video_color_matrix_once.get(gst_video_color_matrix_register);
}

var gst_video_transfer_function_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_TRANSFER_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_TRANSFER_GAMMA10", .value_nick = "gamma10" },
    .{ .value = 2, .value_name = "GST_VIDEO_TRANSFER_GAMMA18", .value_nick = "gamma18" },
    .{ .value = 3, .value_name = "GST_VIDEO_TRANSFER_GAMMA20", .value_nick = "gamma20" },
    .{ .value = 4, .value_name = "GST_VIDEO_TRANSFER_GAMMA22", .value_nick = "gamma22" },
    .{ .value = 5, .value_name = "GST_VIDEO_TRANSFER_BT709", .value_nick = "bt709" },
    .{ .value = 6, .value_name = "GST_VIDEO_TRANSFER_SMPTE240M", .value_nick = "smpte240m" },
    .{ .value = 7, .value_name = "GST_VIDEO_TRANSFER_SRGB", .value_nick = "srgb" },
    .{ .value = 8, .value_name = "GST_VIDEO_TRANSFER_GAMMA28", .value_nick = "gamma28" },
    .{ .value = 9, .value_name = "GST_VIDEO_TRANSFER_LOG100", .value_nick = "log100" },
    .{ .value = 10, .value_name = "GST_VIDEO_TRANSFER_LOG316", .value_nick = "log316" },
    .{ .value = 11, .value_name = "GST_VIDEO_TRANSFER_BT2020_12", .value_nick = "bt2020-12" },
    .{ .value = 12, .value_name = "GST_VIDEO_TRANSFER_ADOBERGB", .value_nick = "adobergb" },
    .{ .value = 13, .value_name = "GST_VIDEO_TRANSFER_BT2020_10", .value_nick = "bt2020-10" },
    .{ .value = 14, .value_name = "GST_VIDEO_TRANSFER_SMPTE2084", .value_nick = "smpte2084" },
    .{ .value = 15, .value_name = "GST_VIDEO_TRANSFER_ARIB_STD_B67", .value_nick = "arib-std-b67" },
    .{ .value = 16, .value_name = "GST_VIDEO_TRANSFER_BT601", .value_nick = "bt601" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_transfer_function_once: gtype.Once = .{};
fn gst_video_transfer_function_register() c.GType {
    return c.g_enum_register_static("GstVideoTransferFunction", &gst_video_transfer_function_values);
}
pub export fn gst_video_transfer_function_get_type() c.GType {
    return gst_video_transfer_function_once.get(gst_video_transfer_function_register);
}

var gst_video_color_primaries_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_COLOR_PRIMARIES_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_COLOR_PRIMARIES_BT709", .value_nick = "bt709" },
    .{ .value = 2, .value_name = "GST_VIDEO_COLOR_PRIMARIES_BT470M", .value_nick = "bt470m" },
    .{ .value = 3, .value_name = "GST_VIDEO_COLOR_PRIMARIES_BT470BG", .value_nick = "bt470bg" },
    .{ .value = 4, .value_name = "GST_VIDEO_COLOR_PRIMARIES_SMPTE170M", .value_nick = "smpte170m" },
    .{ .value = 5, .value_name = "GST_VIDEO_COLOR_PRIMARIES_SMPTE240M", .value_nick = "smpte240m" },
    .{ .value = 6, .value_name = "GST_VIDEO_COLOR_PRIMARIES_FILM", .value_nick = "film" },
    .{ .value = 7, .value_name = "GST_VIDEO_COLOR_PRIMARIES_BT2020", .value_nick = "bt2020" },
    .{ .value = 8, .value_name = "GST_VIDEO_COLOR_PRIMARIES_ADOBERGB", .value_nick = "adobergb" },
    .{ .value = 9, .value_name = "GST_VIDEO_COLOR_PRIMARIES_SMPTEST428", .value_nick = "smptest428" },
    .{ .value = 10, .value_name = "GST_VIDEO_COLOR_PRIMARIES_SMPTERP431", .value_nick = "smpterp431" },
    .{ .value = 11, .value_name = "GST_VIDEO_COLOR_PRIMARIES_SMPTEEG432", .value_nick = "smpteeg432" },
    .{ .value = 12, .value_name = "GST_VIDEO_COLOR_PRIMARIES_EBU3213", .value_nick = "ebu3213" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_color_primaries_once: gtype.Once = .{};
fn gst_video_color_primaries_register() c.GType {
    return c.g_enum_register_static("GstVideoColorPrimaries", &gst_video_color_primaries_values);
}
pub export fn gst_video_color_primaries_get_type() c.GType {
    return gst_video_color_primaries_once.get(gst_video_color_primaries_register);
}

var gst_video_alpha_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_ALPHA_MODE_COPY", .value_nick = "copy" },
    .{ .value = 1, .value_name = "GST_VIDEO_ALPHA_MODE_SET", .value_nick = "set" },
    .{ .value = 2, .value_name = "GST_VIDEO_ALPHA_MODE_MULT", .value_nick = "mult" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_alpha_mode_once: gtype.Once = .{};
fn gst_video_alpha_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoAlphaMode", &gst_video_alpha_mode_values);
}
pub export fn gst_video_alpha_mode_get_type() c.GType {
    return gst_video_alpha_mode_once.get(gst_video_alpha_mode_register);
}

var gst_video_chroma_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_CHROMA_MODE_FULL", .value_nick = "full" },
    .{ .value = 1, .value_name = "GST_VIDEO_CHROMA_MODE_UPSAMPLE_ONLY", .value_nick = "upsample-only" },
    .{ .value = 2, .value_name = "GST_VIDEO_CHROMA_MODE_DOWNSAMPLE_ONLY", .value_nick = "downsample-only" },
    .{ .value = 3, .value_name = "GST_VIDEO_CHROMA_MODE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_chroma_mode_once: gtype.Once = .{};
fn gst_video_chroma_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoChromaMode", &gst_video_chroma_mode_values);
}
pub export fn gst_video_chroma_mode_get_type() c.GType {
    return gst_video_chroma_mode_once.get(gst_video_chroma_mode_register);
}

var gst_video_matrix_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_MATRIX_MODE_FULL", .value_nick = "full" },
    .{ .value = 1, .value_name = "GST_VIDEO_MATRIX_MODE_INPUT_ONLY", .value_nick = "input-only" },
    .{ .value = 2, .value_name = "GST_VIDEO_MATRIX_MODE_OUTPUT_ONLY", .value_nick = "output-only" },
    .{ .value = 3, .value_name = "GST_VIDEO_MATRIX_MODE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_matrix_mode_once: gtype.Once = .{};
fn gst_video_matrix_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoMatrixMode", &gst_video_matrix_mode_values);
}
pub export fn gst_video_matrix_mode_get_type() c.GType {
    return gst_video_matrix_mode_once.get(gst_video_matrix_mode_register);
}

var gst_video_gamma_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_GAMMA_MODE_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_GAMMA_MODE_REMAP", .value_nick = "remap" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_gamma_mode_once: gtype.Once = .{};
fn gst_video_gamma_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoGammaMode", &gst_video_gamma_mode_values);
}
pub export fn gst_video_gamma_mode_get_type() c.GType {
    return gst_video_gamma_mode_once.get(gst_video_gamma_mode_register);
}

var gst_video_primaries_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_PRIMARIES_MODE_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_PRIMARIES_MODE_MERGE_ONLY", .value_nick = "merge-only" },
    .{ .value = 2, .value_name = "GST_VIDEO_PRIMARIES_MODE_FAST", .value_nick = "fast" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_primaries_mode_once: gtype.Once = .{};
fn gst_video_primaries_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoPrimariesMode", &gst_video_primaries_mode_values);
}
pub export fn gst_video_primaries_mode_get_type() c.GType {
    return gst_video_primaries_mode_once.get(gst_video_primaries_mode_register);
}

var gst_video_dither_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_DITHER_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_DITHER_VERTERR", .value_nick = "verterr" },
    .{ .value = 2, .value_name = "GST_VIDEO_DITHER_FLOYD_STEINBERG", .value_nick = "floyd-steinberg" },
    .{ .value = 3, .value_name = "GST_VIDEO_DITHER_SIERRA_LITE", .value_nick = "sierra-lite" },
    .{ .value = 4, .value_name = "GST_VIDEO_DITHER_BAYER", .value_nick = "bayer" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_dither_method_once: gtype.Once = .{};
fn gst_video_dither_method_register() c.GType {
    return c.g_enum_register_static("GstVideoDitherMethod", &gst_video_dither_method_values);
}
pub export fn gst_video_dither_method_get_type() c.GType {
    return gst_video_dither_method_once.get(gst_video_dither_method_register);
}

var gst_video_dither_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_DITHER_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_DITHER_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 2, .value_name = "GST_VIDEO_DITHER_FLAG_QUANTIZE", .value_nick = "quantize" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_dither_flags_once: gtype.Once = .{};
fn gst_video_dither_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoDitherFlags", &gst_video_dither_flags_values);
}
pub export fn gst_video_dither_flags_get_type() c.GType {
    return gst_video_dither_flags_once.get(gst_video_dither_flags_register);
}

var gst_video_format_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_FORMAT_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_FORMAT_ENCODED", .value_nick = "encoded" },
    .{ .value = 2, .value_name = "GST_VIDEO_FORMAT_I420", .value_nick = "i420" },
    .{ .value = 3, .value_name = "GST_VIDEO_FORMAT_YV12", .value_nick = "yv12" },
    .{ .value = 4, .value_name = "GST_VIDEO_FORMAT_YUY2", .value_nick = "yuy2" },
    .{ .value = 5, .value_name = "GST_VIDEO_FORMAT_UYVY", .value_nick = "uyvy" },
    .{ .value = 6, .value_name = "GST_VIDEO_FORMAT_AYUV", .value_nick = "ayuv" },
    .{ .value = 7, .value_name = "GST_VIDEO_FORMAT_RGBx", .value_nick = "rgbx" },
    .{ .value = 8, .value_name = "GST_VIDEO_FORMAT_BGRx", .value_nick = "bgrx" },
    .{ .value = 9, .value_name = "GST_VIDEO_FORMAT_xRGB", .value_nick = "xrgb" },
    .{ .value = 10, .value_name = "GST_VIDEO_FORMAT_xBGR", .value_nick = "xbgr" },
    .{ .value = 11, .value_name = "GST_VIDEO_FORMAT_RGBA", .value_nick = "rgba" },
    .{ .value = 12, .value_name = "GST_VIDEO_FORMAT_BGRA", .value_nick = "bgra" },
    .{ .value = 13, .value_name = "GST_VIDEO_FORMAT_ARGB", .value_nick = "argb" },
    .{ .value = 14, .value_name = "GST_VIDEO_FORMAT_ABGR", .value_nick = "abgr" },
    .{ .value = 15, .value_name = "GST_VIDEO_FORMAT_RGB", .value_nick = "rgb" },
    .{ .value = 16, .value_name = "GST_VIDEO_FORMAT_BGR", .value_nick = "bgr" },
    .{ .value = 17, .value_name = "GST_VIDEO_FORMAT_Y41B", .value_nick = "y41b" },
    .{ .value = 18, .value_name = "GST_VIDEO_FORMAT_Y42B", .value_nick = "y42b" },
    .{ .value = 19, .value_name = "GST_VIDEO_FORMAT_YVYU", .value_nick = "yvyu" },
    .{ .value = 20, .value_name = "GST_VIDEO_FORMAT_Y444", .value_nick = "y444" },
    .{ .value = 21, .value_name = "GST_VIDEO_FORMAT_v210", .value_nick = "v210" },
    .{ .value = 22, .value_name = "GST_VIDEO_FORMAT_v216", .value_nick = "v216" },
    .{ .value = 23, .value_name = "GST_VIDEO_FORMAT_NV12", .value_nick = "nv12" },
    .{ .value = 24, .value_name = "GST_VIDEO_FORMAT_NV21", .value_nick = "nv21" },
    .{ .value = 25, .value_name = "GST_VIDEO_FORMAT_GRAY8", .value_nick = "gray8" },
    .{ .value = 26, .value_name = "GST_VIDEO_FORMAT_GRAY16_BE", .value_nick = "gray16-be" },
    .{ .value = 27, .value_name = "GST_VIDEO_FORMAT_GRAY16_LE", .value_nick = "gray16-le" },
    .{ .value = 28, .value_name = "GST_VIDEO_FORMAT_v308", .value_nick = "v308" },
    .{ .value = 29, .value_name = "GST_VIDEO_FORMAT_RGB16", .value_nick = "rgb16" },
    .{ .value = 30, .value_name = "GST_VIDEO_FORMAT_BGR16", .value_nick = "bgr16" },
    .{ .value = 31, .value_name = "GST_VIDEO_FORMAT_RGB15", .value_nick = "rgb15" },
    .{ .value = 32, .value_name = "GST_VIDEO_FORMAT_BGR15", .value_nick = "bgr15" },
    .{ .value = 33, .value_name = "GST_VIDEO_FORMAT_UYVP", .value_nick = "uyvp" },
    .{ .value = 34, .value_name = "GST_VIDEO_FORMAT_A420", .value_nick = "a420" },
    .{ .value = 35, .value_name = "GST_VIDEO_FORMAT_RGB8P", .value_nick = "rgb8p" },
    .{ .value = 36, .value_name = "GST_VIDEO_FORMAT_YUV9", .value_nick = "yuv9" },
    .{ .value = 37, .value_name = "GST_VIDEO_FORMAT_YVU9", .value_nick = "yvu9" },
    .{ .value = 38, .value_name = "GST_VIDEO_FORMAT_IYU1", .value_nick = "iyu1" },
    .{ .value = 39, .value_name = "GST_VIDEO_FORMAT_ARGB64", .value_nick = "argb64" },
    .{ .value = 40, .value_name = "GST_VIDEO_FORMAT_AYUV64", .value_nick = "ayuv64" },
    .{ .value = 41, .value_name = "GST_VIDEO_FORMAT_r210", .value_nick = "r210" },
    .{ .value = 42, .value_name = "GST_VIDEO_FORMAT_I420_10BE", .value_nick = "i420-10be" },
    .{ .value = 43, .value_name = "GST_VIDEO_FORMAT_I420_10LE", .value_nick = "i420-10le" },
    .{ .value = 44, .value_name = "GST_VIDEO_FORMAT_I422_10BE", .value_nick = "i422-10be" },
    .{ .value = 45, .value_name = "GST_VIDEO_FORMAT_I422_10LE", .value_nick = "i422-10le" },
    .{ .value = 46, .value_name = "GST_VIDEO_FORMAT_Y444_10BE", .value_nick = "y444-10be" },
    .{ .value = 47, .value_name = "GST_VIDEO_FORMAT_Y444_10LE", .value_nick = "y444-10le" },
    .{ .value = 48, .value_name = "GST_VIDEO_FORMAT_GBR", .value_nick = "gbr" },
    .{ .value = 49, .value_name = "GST_VIDEO_FORMAT_GBR_10BE", .value_nick = "gbr-10be" },
    .{ .value = 50, .value_name = "GST_VIDEO_FORMAT_GBR_10LE", .value_nick = "gbr-10le" },
    .{ .value = 51, .value_name = "GST_VIDEO_FORMAT_NV16", .value_nick = "nv16" },
    .{ .value = 52, .value_name = "GST_VIDEO_FORMAT_NV24", .value_nick = "nv24" },
    .{ .value = 53, .value_name = "GST_VIDEO_FORMAT_NV12_64Z32", .value_nick = "nv12-64z32" },
    .{ .value = 54, .value_name = "GST_VIDEO_FORMAT_A420_10BE", .value_nick = "a420-10be" },
    .{ .value = 55, .value_name = "GST_VIDEO_FORMAT_A420_10LE", .value_nick = "a420-10le" },
    .{ .value = 56, .value_name = "GST_VIDEO_FORMAT_A422_10BE", .value_nick = "a422-10be" },
    .{ .value = 57, .value_name = "GST_VIDEO_FORMAT_A422_10LE", .value_nick = "a422-10le" },
    .{ .value = 58, .value_name = "GST_VIDEO_FORMAT_A444_10BE", .value_nick = "a444-10be" },
    .{ .value = 59, .value_name = "GST_VIDEO_FORMAT_A444_10LE", .value_nick = "a444-10le" },
    .{ .value = 60, .value_name = "GST_VIDEO_FORMAT_NV61", .value_nick = "nv61" },
    .{ .value = 61, .value_name = "GST_VIDEO_FORMAT_P010_10BE", .value_nick = "p010-10be" },
    .{ .value = 62, .value_name = "GST_VIDEO_FORMAT_P010_10LE", .value_nick = "p010-10le" },
    .{ .value = 63, .value_name = "GST_VIDEO_FORMAT_IYU2", .value_nick = "iyu2" },
    .{ .value = 64, .value_name = "GST_VIDEO_FORMAT_VYUY", .value_nick = "vyuy" },
    .{ .value = 65, .value_name = "GST_VIDEO_FORMAT_GBRA", .value_nick = "gbra" },
    .{ .value = 66, .value_name = "GST_VIDEO_FORMAT_GBRA_10BE", .value_nick = "gbra-10be" },
    .{ .value = 67, .value_name = "GST_VIDEO_FORMAT_GBRA_10LE", .value_nick = "gbra-10le" },
    .{ .value = 68, .value_name = "GST_VIDEO_FORMAT_GBR_12BE", .value_nick = "gbr-12be" },
    .{ .value = 69, .value_name = "GST_VIDEO_FORMAT_GBR_12LE", .value_nick = "gbr-12le" },
    .{ .value = 70, .value_name = "GST_VIDEO_FORMAT_GBRA_12BE", .value_nick = "gbra-12be" },
    .{ .value = 71, .value_name = "GST_VIDEO_FORMAT_GBRA_12LE", .value_nick = "gbra-12le" },
    .{ .value = 72, .value_name = "GST_VIDEO_FORMAT_I420_12BE", .value_nick = "i420-12be" },
    .{ .value = 73, .value_name = "GST_VIDEO_FORMAT_I420_12LE", .value_nick = "i420-12le" },
    .{ .value = 74, .value_name = "GST_VIDEO_FORMAT_I422_12BE", .value_nick = "i422-12be" },
    .{ .value = 75, .value_name = "GST_VIDEO_FORMAT_I422_12LE", .value_nick = "i422-12le" },
    .{ .value = 76, .value_name = "GST_VIDEO_FORMAT_Y444_12BE", .value_nick = "y444-12be" },
    .{ .value = 77, .value_name = "GST_VIDEO_FORMAT_Y444_12LE", .value_nick = "y444-12le" },
    .{ .value = 78, .value_name = "GST_VIDEO_FORMAT_GRAY10_LE32", .value_nick = "gray10-le32" },
    .{ .value = 79, .value_name = "GST_VIDEO_FORMAT_NV12_10LE32", .value_nick = "nv12-10le32" },
    .{ .value = 80, .value_name = "GST_VIDEO_FORMAT_NV16_10LE32", .value_nick = "nv16-10le32" },
    .{ .value = 81, .value_name = "GST_VIDEO_FORMAT_NV12_10LE40", .value_nick = "nv12-10le40" },
    .{ .value = 82, .value_name = "GST_VIDEO_FORMAT_Y210", .value_nick = "y210" },
    .{ .value = 83, .value_name = "GST_VIDEO_FORMAT_Y410", .value_nick = "y410" },
    .{ .value = 84, .value_name = "GST_VIDEO_FORMAT_VUYA", .value_nick = "vuya" },
    .{ .value = 85, .value_name = "GST_VIDEO_FORMAT_BGR10A2_LE", .value_nick = "bgr10a2-le" },
    .{ .value = 86, .value_name = "GST_VIDEO_FORMAT_RGB10A2_LE", .value_nick = "rgb10a2-le" },
    .{ .value = 87, .value_name = "GST_VIDEO_FORMAT_Y444_16BE", .value_nick = "y444-16be" },
    .{ .value = 88, .value_name = "GST_VIDEO_FORMAT_Y444_16LE", .value_nick = "y444-16le" },
    .{ .value = 89, .value_name = "GST_VIDEO_FORMAT_P016_BE", .value_nick = "p016-be" },
    .{ .value = 90, .value_name = "GST_VIDEO_FORMAT_P016_LE", .value_nick = "p016-le" },
    .{ .value = 91, .value_name = "GST_VIDEO_FORMAT_P012_BE", .value_nick = "p012-be" },
    .{ .value = 92, .value_name = "GST_VIDEO_FORMAT_P012_LE", .value_nick = "p012-le" },
    .{ .value = 93, .value_name = "GST_VIDEO_FORMAT_Y212_BE", .value_nick = "y212-be" },
    .{ .value = 94, .value_name = "GST_VIDEO_FORMAT_Y212_LE", .value_nick = "y212-le" },
    .{ .value = 95, .value_name = "GST_VIDEO_FORMAT_Y412_BE", .value_nick = "y412-be" },
    .{ .value = 96, .value_name = "GST_VIDEO_FORMAT_Y412_LE", .value_nick = "y412-le" },
    .{ .value = 97, .value_name = "GST_VIDEO_FORMAT_NV12_4L4", .value_nick = "nv12-4l4" },
    .{ .value = 98, .value_name = "GST_VIDEO_FORMAT_NV12_32L32", .value_nick = "nv12-32l32" },
    .{ .value = 99, .value_name = "GST_VIDEO_FORMAT_RGBP", .value_nick = "rgbp" },
    .{ .value = 100, .value_name = "GST_VIDEO_FORMAT_BGRP", .value_nick = "bgrp" },
    .{ .value = 101, .value_name = "GST_VIDEO_FORMAT_AV12", .value_nick = "av12" },
    .{ .value = 102, .value_name = "GST_VIDEO_FORMAT_ARGB64_LE", .value_nick = "argb64-le" },
    .{ .value = 103, .value_name = "GST_VIDEO_FORMAT_ARGB64_BE", .value_nick = "argb64-be" },
    .{ .value = 104, .value_name = "GST_VIDEO_FORMAT_RGBA64_LE", .value_nick = "rgba64-le" },
    .{ .value = 105, .value_name = "GST_VIDEO_FORMAT_RGBA64_BE", .value_nick = "rgba64-be" },
    .{ .value = 106, .value_name = "GST_VIDEO_FORMAT_BGRA64_LE", .value_nick = "bgra64-le" },
    .{ .value = 107, .value_name = "GST_VIDEO_FORMAT_BGRA64_BE", .value_nick = "bgra64-be" },
    .{ .value = 108, .value_name = "GST_VIDEO_FORMAT_ABGR64_LE", .value_nick = "abgr64-le" },
    .{ .value = 109, .value_name = "GST_VIDEO_FORMAT_ABGR64_BE", .value_nick = "abgr64-be" },
    .{ .value = 110, .value_name = "GST_VIDEO_FORMAT_NV12_16L32S", .value_nick = "nv12-16l32s" },
    .{ .value = 111, .value_name = "GST_VIDEO_FORMAT_NV12_8L128", .value_nick = "nv12-8l128" },
    .{ .value = 112, .value_name = "GST_VIDEO_FORMAT_NV12_10BE_8L128", .value_nick = "nv12-10be-8l128" },
    .{ .value = 113, .value_name = "GST_VIDEO_FORMAT_NV12_10LE40_4L4", .value_nick = "nv12-10le40-4l4" },
    .{ .value = 114, .value_name = "GST_VIDEO_FORMAT_DMA_DRM", .value_nick = "dma-drm" },
    .{ .value = 115, .value_name = "GST_VIDEO_FORMAT_MT2110T", .value_nick = "mt2110t" },
    .{ .value = 116, .value_name = "GST_VIDEO_FORMAT_MT2110R", .value_nick = "mt2110r" },
    .{ .value = 117, .value_name = "GST_VIDEO_FORMAT_A422", .value_nick = "a422" },
    .{ .value = 118, .value_name = "GST_VIDEO_FORMAT_A444", .value_nick = "a444" },
    .{ .value = 119, .value_name = "GST_VIDEO_FORMAT_A444_12LE", .value_nick = "a444-12le" },
    .{ .value = 120, .value_name = "GST_VIDEO_FORMAT_A444_12BE", .value_nick = "a444-12be" },
    .{ .value = 121, .value_name = "GST_VIDEO_FORMAT_A422_12LE", .value_nick = "a422-12le" },
    .{ .value = 122, .value_name = "GST_VIDEO_FORMAT_A422_12BE", .value_nick = "a422-12be" },
    .{ .value = 123, .value_name = "GST_VIDEO_FORMAT_A420_12LE", .value_nick = "a420-12le" },
    .{ .value = 124, .value_name = "GST_VIDEO_FORMAT_A420_12BE", .value_nick = "a420-12be" },
    .{ .value = 125, .value_name = "GST_VIDEO_FORMAT_A444_16LE", .value_nick = "a444-16le" },
    .{ .value = 126, .value_name = "GST_VIDEO_FORMAT_A444_16BE", .value_nick = "a444-16be" },
    .{ .value = 127, .value_name = "GST_VIDEO_FORMAT_A422_16LE", .value_nick = "a422-16le" },
    .{ .value = 128, .value_name = "GST_VIDEO_FORMAT_A422_16BE", .value_nick = "a422-16be" },
    .{ .value = 129, .value_name = "GST_VIDEO_FORMAT_A420_16LE", .value_nick = "a420-16le" },
    .{ .value = 130, .value_name = "GST_VIDEO_FORMAT_A420_16BE", .value_nick = "a420-16be" },
    .{ .value = 131, .value_name = "GST_VIDEO_FORMAT_GBR_16LE", .value_nick = "gbr-16le" },
    .{ .value = 132, .value_name = "GST_VIDEO_FORMAT_GBR_16BE", .value_nick = "gbr-16be" },
    .{ .value = 133, .value_name = "GST_VIDEO_FORMAT_RBGA", .value_nick = "rbga" },
    .{ .value = 134, .value_name = "GST_VIDEO_FORMAT_Y216_LE", .value_nick = "y216-le" },
    .{ .value = 135, .value_name = "GST_VIDEO_FORMAT_Y216_BE", .value_nick = "y216-be" },
    .{ .value = 136, .value_name = "GST_VIDEO_FORMAT_Y416_LE", .value_nick = "y416-le" },
    .{ .value = 137, .value_name = "GST_VIDEO_FORMAT_Y416_BE", .value_nick = "y416-be" },
    .{ .value = 138, .value_name = "GST_VIDEO_FORMAT_GRAY10_LE16", .value_nick = "gray10-le16" },
    .{ .value = 139, .value_name = "GST_VIDEO_FORMAT_NV16_10LE40", .value_nick = "nv16-10le40" },
    .{ .value = 140, .value_name = "GST_VIDEO_FORMAT_BGR10x2_LE", .value_nick = "bgr10x2-le" },
    .{ .value = 141, .value_name = "GST_VIDEO_FORMAT_RGB10x2_LE", .value_nick = "rgb10x2-le" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_format_once: gtype.Once = .{};
fn gst_video_format_register() c.GType {
    return c.g_enum_register_static("GstVideoFormat", &gst_video_format_values);
}
pub export fn gst_video_format_get_type() c.GType {
    return gst_video_format_once.get(gst_video_format_register);
}

var gst_video_format_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_VIDEO_FORMAT_FLAG_YUV", .value_nick = "yuv" },
    .{ .value = 2, .value_name = "GST_VIDEO_FORMAT_FLAG_RGB", .value_nick = "rgb" },
    .{ .value = 4, .value_name = "GST_VIDEO_FORMAT_FLAG_GRAY", .value_nick = "gray" },
    .{ .value = 8, .value_name = "GST_VIDEO_FORMAT_FLAG_ALPHA", .value_nick = "alpha" },
    .{ .value = 16, .value_name = "GST_VIDEO_FORMAT_FLAG_LE", .value_nick = "le" },
    .{ .value = 32, .value_name = "GST_VIDEO_FORMAT_FLAG_PALETTE", .value_nick = "palette" },
    .{ .value = 64, .value_name = "GST_VIDEO_FORMAT_FLAG_COMPLEX", .value_nick = "complex" },
    .{ .value = 128, .value_name = "GST_VIDEO_FORMAT_FLAG_UNPACK", .value_nick = "unpack" },
    .{ .value = 256, .value_name = "GST_VIDEO_FORMAT_FLAG_TILED", .value_nick = "tiled" },
    .{ .value = 512, .value_name = "GST_VIDEO_FORMAT_FLAG_SUBTILES", .value_nick = "subtiles" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_format_flags_once: gtype.Once = .{};
fn gst_video_format_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoFormatFlags", &gst_video_format_flags_values);
}
pub export fn gst_video_format_flags_get_type() c.GType {
    return gst_video_format_flags_once.get(gst_video_format_flags_register);
}

var gst_video_pack_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_PACK_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_PACK_FLAG_TRUNCATE_RANGE", .value_nick = "truncate-range" },
    .{ .value = 2, .value_name = "GST_VIDEO_PACK_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_pack_flags_once: gtype.Once = .{};
fn gst_video_pack_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoPackFlags", &gst_video_pack_flags_values);
}
pub export fn gst_video_pack_flags_get_type() c.GType {
    return gst_video_pack_flags_once.get(gst_video_pack_flags_register);
}

var gst_video_frame_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_FRAME_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_FRAME_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 2, .value_name = "GST_VIDEO_FRAME_FLAG_TFF", .value_nick = "tff" },
    .{ .value = 4, .value_name = "GST_VIDEO_FRAME_FLAG_RFF", .value_nick = "rff" },
    .{ .value = 8, .value_name = "GST_VIDEO_FRAME_FLAG_ONEFIELD", .value_nick = "onefield" },
    .{ .value = 16, .value_name = "GST_VIDEO_FRAME_FLAG_MULTIPLE_VIEW", .value_nick = "multiple-view" },
    .{ .value = 32, .value_name = "GST_VIDEO_FRAME_FLAG_FIRST_IN_BUNDLE", .value_nick = "first-in-bundle" },
    .{ .value = 10, .value_name = "GST_VIDEO_FRAME_FLAG_TOP_FIELD", .value_nick = "top-field" },
    .{ .value = 8, .value_name = "GST_VIDEO_FRAME_FLAG_ONEFIELD", .value_nick = "onefield" },
    .{ .value = 8, .value_name = "GST_VIDEO_FRAME_FLAG_BOTTOM_FIELD", .value_nick = "bottom-field" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_frame_flags_once: gtype.Once = .{};
fn gst_video_frame_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoFrameFlags", &gst_video_frame_flags_values);
}
pub export fn gst_video_frame_flags_get_type() c.GType {
    return gst_video_frame_flags_once.get(gst_video_frame_flags_register);
}

var gst_video_buffer_flags_values = [_]c.GFlagsValue{
    .{ .value = 1048576, .value_name = "GST_VIDEO_BUFFER_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 2097152, .value_name = "GST_VIDEO_BUFFER_FLAG_TFF", .value_nick = "tff" },
    .{ .value = 4194304, .value_name = "GST_VIDEO_BUFFER_FLAG_RFF", .value_nick = "rff" },
    .{ .value = 8388608, .value_name = "GST_VIDEO_BUFFER_FLAG_ONEFIELD", .value_nick = "onefield" },
    .{ .value = 16777216, .value_name = "GST_VIDEO_BUFFER_FLAG_MULTIPLE_VIEW", .value_nick = "multiple-view" },
    .{ .value = 33554432, .value_name = "GST_VIDEO_BUFFER_FLAG_FIRST_IN_BUNDLE", .value_nick = "first-in-bundle" },
    .{ .value = 10485760, .value_name = "GST_VIDEO_BUFFER_FLAG_TOP_FIELD", .value_nick = "top-field" },
    .{ .value = 8388608, .value_name = "GST_VIDEO_BUFFER_FLAG_ONEFIELD", .value_nick = "onefield" },
    .{ .value = 8388608, .value_name = "GST_VIDEO_BUFFER_FLAG_BOTTOM_FIELD", .value_nick = "bottom-field" },
    .{ .value = 512, .value_name = "GST_VIDEO_BUFFER_FLAG_MARKER", .value_nick = "marker" },
    .{ .value = 268435456, .value_name = "GST_VIDEO_BUFFER_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_buffer_flags_once: gtype.Once = .{};
fn gst_video_buffer_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoBufferFlags", &gst_video_buffer_flags_values);
}
pub export fn gst_video_buffer_flags_get_type() c.GType {
    return gst_video_buffer_flags_once.get(gst_video_buffer_flags_register);
}

var gst_video_frame_map_flags_values = [_]c.GFlagsValue{
    .{ .value = 65536, .value_name = "GST_VIDEO_FRAME_MAP_FLAG_NO_REF", .value_nick = "no-ref" },
    .{ .value = 16777216, .value_name = "GST_VIDEO_FRAME_MAP_FLAG_LAST", .value_nick = "last" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_frame_map_flags_once: gtype.Once = .{};
fn gst_video_frame_map_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoFrameMapFlags", &gst_video_frame_map_flags_values);
}
pub export fn gst_video_frame_map_flags_get_type() c.GType {
    return gst_video_frame_map_flags_once.get(gst_video_frame_map_flags_register);
}

var gst_video_interlace_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_INTERLACE_MODE_PROGRESSIVE", .value_nick = "progressive" },
    .{ .value = 1, .value_name = "GST_VIDEO_INTERLACE_MODE_INTERLEAVED", .value_nick = "interleaved" },
    .{ .value = 2, .value_name = "GST_VIDEO_INTERLACE_MODE_MIXED", .value_nick = "mixed" },
    .{ .value = 3, .value_name = "GST_VIDEO_INTERLACE_MODE_FIELDS", .value_nick = "fields" },
    .{ .value = 4, .value_name = "GST_VIDEO_INTERLACE_MODE_ALTERNATE", .value_nick = "alternate" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_interlace_mode_once: gtype.Once = .{};
fn gst_video_interlace_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoInterlaceMode", &gst_video_interlace_mode_values);
}
pub export fn gst_video_interlace_mode_get_type() c.GType {
    return gst_video_interlace_mode_once.get(gst_video_interlace_mode_register);
}

var gst_video_multiview_mode_values = [_]c.GEnumValue{
    .{ .value = -1, .value_name = "GST_VIDEO_MULTIVIEW_MODE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = "GST_VIDEO_MULTIVIEW_MODE_MONO", .value_nick = "mono" },
    .{ .value = 1, .value_name = "GST_VIDEO_MULTIVIEW_MODE_LEFT", .value_nick = "left" },
    .{ .value = 2, .value_name = "GST_VIDEO_MULTIVIEW_MODE_RIGHT", .value_nick = "right" },
    .{ .value = 3, .value_name = "GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE", .value_nick = "side-by-side" },
    .{ .value = 4, .value_name = "GST_VIDEO_MULTIVIEW_MODE_SIDE_BY_SIDE_QUINCUNX", .value_nick = "side-by-side-quincunx" },
    .{ .value = 5, .value_name = "GST_VIDEO_MULTIVIEW_MODE_COLUMN_INTERLEAVED", .value_nick = "column-interleaved" },
    .{ .value = 6, .value_name = "GST_VIDEO_MULTIVIEW_MODE_ROW_INTERLEAVED", .value_nick = "row-interleaved" },
    .{ .value = 7, .value_name = "GST_VIDEO_MULTIVIEW_MODE_TOP_BOTTOM", .value_nick = "top-bottom" },
    .{ .value = 8, .value_name = "GST_VIDEO_MULTIVIEW_MODE_CHECKERBOARD", .value_nick = "checkerboard" },
    .{ .value = 32, .value_name = "GST_VIDEO_MULTIVIEW_MODE_FRAME_BY_FRAME", .value_nick = "frame-by-frame" },
    .{ .value = 33, .value_name = "GST_VIDEO_MULTIVIEW_MODE_MULTIVIEW_FRAME_BY_FRAME", .value_nick = "multiview-frame-by-frame" },
    .{ .value = 34, .value_name = "GST_VIDEO_MULTIVIEW_MODE_SEPARATED", .value_nick = "separated" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_multiview_mode_once: gtype.Once = .{};
fn gst_video_multiview_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoMultiviewMode", &gst_video_multiview_mode_values);
}
pub export fn gst_video_multiview_mode_get_type() c.GType {
    return gst_video_multiview_mode_once.get(gst_video_multiview_mode_register);
}

var gst_video_multiview_frame_packing_values = [_]c.GEnumValue{
    .{ .value = -1, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_MONO", .value_nick = "mono" },
    .{ .value = 1, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_LEFT", .value_nick = "left" },
    .{ .value = 2, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_RIGHT", .value_nick = "right" },
    .{ .value = 3, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_SIDE_BY_SIDE", .value_nick = "side-by-side" },
    .{ .value = 4, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_SIDE_BY_SIDE_QUINCUNX", .value_nick = "side-by-side-quincunx" },
    .{ .value = 5, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_COLUMN_INTERLEAVED", .value_nick = "column-interleaved" },
    .{ .value = 6, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_ROW_INTERLEAVED", .value_nick = "row-interleaved" },
    .{ .value = 7, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_TOP_BOTTOM", .value_nick = "top-bottom" },
    .{ .value = 8, .value_name = "GST_VIDEO_MULTIVIEW_FRAME_PACKING_CHECKERBOARD", .value_nick = "checkerboard" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_multiview_frame_packing_once: gtype.Once = .{};
fn gst_video_multiview_frame_packing_register() c.GType {
    return c.g_enum_register_static("GstVideoMultiviewFramePacking", &gst_video_multiview_frame_packing_values);
}
pub export fn gst_video_multiview_frame_packing_get_type() c.GType {
    return gst_video_multiview_frame_packing_once.get(gst_video_multiview_frame_packing_register);
}

var gst_video_multiview_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_VIEW_FIRST", .value_nick = "right-view-first" },
    .{ .value = 2, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLIPPED", .value_nick = "left-flipped" },
    .{ .value = 4, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_LEFT_FLOPPED", .value_nick = "left-flopped" },
    .{ .value = 8, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLIPPED", .value_nick = "right-flipped" },
    .{ .value = 16, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_RIGHT_FLOPPED", .value_nick = "right-flopped" },
    .{ .value = 16384, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_HALF_ASPECT", .value_nick = "half-aspect" },
    .{ .value = 32768, .value_name = "GST_VIDEO_MULTIVIEW_FLAGS_MIXED_MONO", .value_nick = "mixed-mono" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_multiview_flags_once: gtype.Once = .{};
fn gst_video_multiview_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoMultiviewFlags", &gst_video_multiview_flags_values);
}
pub export fn gst_video_multiview_flags_get_type() c.GType {
    return gst_video_multiview_flags_once.get(gst_video_multiview_flags_register);
}

var gst_video_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_FLAG_VARIABLE_FPS", .value_nick = "variable-fps" },
    .{ .value = 2, .value_name = "GST_VIDEO_FLAG_PREMULTIPLIED_ALPHA", .value_nick = "premultiplied-alpha" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_flags_once: gtype.Once = .{};
fn gst_video_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoFlags", &gst_video_flags_values);
}
pub export fn gst_video_flags_get_type() c.GType {
    return gst_video_flags_once.get(gst_video_flags_register);
}

var gst_video_field_order_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_FIELD_ORDER_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_VIDEO_FIELD_ORDER_TOP_FIELD_FIRST", .value_nick = "top-field-first" },
    .{ .value = 2, .value_name = "GST_VIDEO_FIELD_ORDER_BOTTOM_FIELD_FIRST", .value_nick = "bottom-field-first" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_field_order_once: gtype.Once = .{};
fn gst_video_field_order_register() c.GType {
    return c.g_enum_register_static("GstVideoFieldOrder", &gst_video_field_order_values);
}
pub export fn gst_video_field_order_get_type() c.GType {
    return gst_video_field_order_once.get(gst_video_field_order_register);
}

var gst_video_overlay_format_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_OVERLAY_FORMAT_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_OVERLAY_FORMAT_FLAG_PREMULTIPLIED_ALPHA", .value_nick = "premultiplied-alpha" },
    .{ .value = 2, .value_name = "GST_VIDEO_OVERLAY_FORMAT_FLAG_GLOBAL_ALPHA", .value_nick = "global-alpha" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_overlay_format_flags_once: gtype.Once = .{};
fn gst_video_overlay_format_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoOverlayFormatFlags", &gst_video_overlay_format_flags_values);
}
pub export fn gst_video_overlay_format_flags_get_type() c.GType {
    return gst_video_overlay_format_flags_once.get(gst_video_overlay_format_flags_register);
}

var gst_video_resampler_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_RESAMPLER_METHOD_NEAREST", .value_nick = "nearest" },
    .{ .value = 1, .value_name = "GST_VIDEO_RESAMPLER_METHOD_LINEAR", .value_nick = "linear" },
    .{ .value = 2, .value_name = "GST_VIDEO_RESAMPLER_METHOD_CUBIC", .value_nick = "cubic" },
    .{ .value = 3, .value_name = "GST_VIDEO_RESAMPLER_METHOD_SINC", .value_nick = "sinc" },
    .{ .value = 4, .value_name = "GST_VIDEO_RESAMPLER_METHOD_LANCZOS", .value_nick = "lanczos" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_resampler_method_once: gtype.Once = .{};
fn gst_video_resampler_method_register() c.GType {
    return c.g_enum_register_static("GstVideoResamplerMethod", &gst_video_resampler_method_values);
}
pub export fn gst_video_resampler_method_get_type() c.GType {
    return gst_video_resampler_method_once.get(gst_video_resampler_method_register);
}

var gst_video_resampler_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_RESAMPLER_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_RESAMPLER_FLAG_HALF_TAPS", .value_nick = "half-taps" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_resampler_flags_once: gtype.Once = .{};
fn gst_video_resampler_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoResamplerFlags", &gst_video_resampler_flags_values);
}
pub export fn gst_video_resampler_flags_get_type() c.GType {
    return gst_video_resampler_flags_once.get(gst_video_resampler_flags_register);
}

var gst_video_scaler_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_VIDEO_SCALER_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_VIDEO_SCALER_FLAG_INTERLACED", .value_nick = "interlaced" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_scaler_flags_once: gtype.Once = .{};
fn gst_video_scaler_flags_register() c.GType {
    return c.g_flags_register_static("GstVideoScalerFlags", &gst_video_scaler_flags_values);
}
pub export fn gst_video_scaler_flags_get_type() c.GType {
    return gst_video_scaler_flags_once.get(gst_video_scaler_flags_register);
}

var gst_video_tile_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_TILE_TYPE_INDEXED", .value_nick = "indexed" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_tile_type_once: gtype.Once = .{};
fn gst_video_tile_type_register() c.GType {
    return c.g_enum_register_static("GstVideoTileType", &gst_video_tile_type_values);
}
pub export fn gst_video_tile_type_get_type() c.GType {
    return gst_video_tile_type_once.get(gst_video_tile_type_register);
}

var gst_video_tile_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_TILE_MODE_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 65536, .value_name = "GST_VIDEO_TILE_MODE_ZFLIPZ_2X2", .value_nick = "zflipz-2x2" },
    .{ .value = 131072, .value_name = "GST_VIDEO_TILE_MODE_LINEAR", .value_nick = "linear" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_tile_mode_once: gtype.Once = .{};
fn gst_video_tile_mode_register() c.GType {
    return c.g_enum_register_static("GstVideoTileMode", &gst_video_tile_mode_values);
}
pub export fn gst_video_tile_mode_get_type() c.GType {
    return gst_video_tile_mode_once.get(gst_video_tile_mode_register);
}

var gst_video_orientation_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_VIDEO_ORIENTATION_IDENTITY", .value_nick = "identity" },
    .{ .value = 1, .value_name = "GST_VIDEO_ORIENTATION_90R", .value_nick = "90r" },
    .{ .value = 2, .value_name = "GST_VIDEO_ORIENTATION_180", .value_nick = "180" },
    .{ .value = 3, .value_name = "GST_VIDEO_ORIENTATION_90L", .value_nick = "90l" },
    .{ .value = 4, .value_name = "GST_VIDEO_ORIENTATION_HORIZ", .value_nick = "horiz" },
    .{ .value = 5, .value_name = "GST_VIDEO_ORIENTATION_VERT", .value_nick = "vert" },
    .{ .value = 6, .value_name = "GST_VIDEO_ORIENTATION_UL_LR", .value_nick = "ul-lr" },
    .{ .value = 7, .value_name = "GST_VIDEO_ORIENTATION_UR_LL", .value_nick = "ur-ll" },
    .{ .value = 8, .value_name = "GST_VIDEO_ORIENTATION_AUTO", .value_nick = "auto" },
    .{ .value = 9, .value_name = "GST_VIDEO_ORIENTATION_CUSTOM", .value_nick = "custom" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_video_orientation_method_once: gtype.Once = .{};
fn gst_video_orientation_method_register() c.GType {
    return c.g_enum_register_static("GstVideoOrientationMethod", &gst_video_orientation_method_values);
}
pub export fn gst_video_orientation_method_get_type() c.GType {
    return gst_video_orientation_method_once.get(gst_video_orientation_method_register);
}
