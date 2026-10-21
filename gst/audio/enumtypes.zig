const c = @import("../c.zig").c;
const gtype = @import("../gtype.zig");

var gst_audio_channel_mixer_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_CHANNEL_MIXER_FLAGS_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_IN", .value_nick = "non-interleaved-in" },
    .{ .value = 2, .value_name = "GST_AUDIO_CHANNEL_MIXER_FLAGS_NON_INTERLEAVED_OUT", .value_nick = "non-interleaved-out" },
    .{ .value = 4, .value_name = "GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_IN", .value_nick = "unpositioned-in" },
    .{ .value = 8, .value_name = "GST_AUDIO_CHANNEL_MIXER_FLAGS_UNPOSITIONED_OUT", .value_nick = "unpositioned-out" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_channel_mixer_flags_once: gtype.Once = .{};
fn gst_audio_channel_mixer_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioChannelMixerFlags", &gst_audio_channel_mixer_flags_values);
}
pub export fn gst_audio_channel_mixer_flags_get_type() c.GType {
    return gst_audio_channel_mixer_flags_once.get(gst_audio_channel_mixer_flags_register);
}

var gst_audio_channel_position_values = [_]c.GEnumValue{
    .{ .value = -3, .value_name = "GST_AUDIO_CHANNEL_POSITION_NONE", .value_nick = "none" },
    .{ .value = -2, .value_name = "GST_AUDIO_CHANNEL_POSITION_MONO", .value_nick = "mono" },
    .{ .value = -1, .value_name = "GST_AUDIO_CHANNEL_POSITION_INVALID", .value_nick = "invalid" },
    .{ .value = 0, .value_name = "GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT", .value_nick = "front-left" },
    .{ .value = 1, .value_name = "GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT", .value_nick = "front-right" },
    .{ .value = 2, .value_name = "GST_AUDIO_CHANNEL_POSITION_FRONT_CENTER", .value_nick = "front-center" },
    .{ .value = 3, .value_name = "GST_AUDIO_CHANNEL_POSITION_LFE1", .value_nick = "lfe1" },
    .{ .value = 4, .value_name = "GST_AUDIO_CHANNEL_POSITION_REAR_LEFT", .value_nick = "rear-left" },
    .{ .value = 5, .value_name = "GST_AUDIO_CHANNEL_POSITION_REAR_RIGHT", .value_nick = "rear-right" },
    .{ .value = 6, .value_name = "GST_AUDIO_CHANNEL_POSITION_FRONT_LEFT_OF_CENTER", .value_nick = "front-left-of-center" },
    .{ .value = 7, .value_name = "GST_AUDIO_CHANNEL_POSITION_FRONT_RIGHT_OF_CENTER", .value_nick = "front-right-of-center" },
    .{ .value = 8, .value_name = "GST_AUDIO_CHANNEL_POSITION_REAR_CENTER", .value_nick = "rear-center" },
    .{ .value = 9, .value_name = "GST_AUDIO_CHANNEL_POSITION_LFE2", .value_nick = "lfe2" },
    .{ .value = 10, .value_name = "GST_AUDIO_CHANNEL_POSITION_SIDE_LEFT", .value_nick = "side-left" },
    .{ .value = 11, .value_name = "GST_AUDIO_CHANNEL_POSITION_SIDE_RIGHT", .value_nick = "side-right" },
    .{ .value = 12, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_LEFT", .value_nick = "top-front-left" },
    .{ .value = 13, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_RIGHT", .value_nick = "top-front-right" },
    .{ .value = 14, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_FRONT_CENTER", .value_nick = "top-front-center" },
    .{ .value = 15, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_CENTER", .value_nick = "top-center" },
    .{ .value = 16, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_REAR_LEFT", .value_nick = "top-rear-left" },
    .{ .value = 17, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_REAR_RIGHT", .value_nick = "top-rear-right" },
    .{ .value = 18, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_SIDE_LEFT", .value_nick = "top-side-left" },
    .{ .value = 19, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_SIDE_RIGHT", .value_nick = "top-side-right" },
    .{ .value = 20, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_REAR_CENTER", .value_nick = "top-rear-center" },
    .{ .value = 21, .value_name = "GST_AUDIO_CHANNEL_POSITION_BOTTOM_FRONT_CENTER", .value_nick = "bottom-front-center" },
    .{ .value = 22, .value_name = "GST_AUDIO_CHANNEL_POSITION_BOTTOM_FRONT_LEFT", .value_nick = "bottom-front-left" },
    .{ .value = 23, .value_name = "GST_AUDIO_CHANNEL_POSITION_BOTTOM_FRONT_RIGHT", .value_nick = "bottom-front-right" },
    .{ .value = 24, .value_name = "GST_AUDIO_CHANNEL_POSITION_WIDE_LEFT", .value_nick = "wide-left" },
    .{ .value = 25, .value_name = "GST_AUDIO_CHANNEL_POSITION_WIDE_RIGHT", .value_nick = "wide-right" },
    .{ .value = 26, .value_name = "GST_AUDIO_CHANNEL_POSITION_SURROUND_LEFT", .value_nick = "surround-left" },
    .{ .value = 27, .value_name = "GST_AUDIO_CHANNEL_POSITION_SURROUND_RIGHT", .value_nick = "surround-right" },
    .{ .value = 28, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_SURROUND_LEFT", .value_nick = "top-surround-left" },
    .{ .value = 29, .value_name = "GST_AUDIO_CHANNEL_POSITION_TOP_SURROUND_RIGHT", .value_nick = "top-surround-right" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_channel_position_once: gtype.Once = .{};
fn gst_audio_channel_position_register() c.GType {
    return c.g_enum_register_static("GstAudioChannelPosition", &gst_audio_channel_position_values);
}
pub export fn gst_audio_channel_position_get_type() c.GType {
    return gst_audio_channel_position_once.get(gst_audio_channel_position_register);
}

var gst_audio_converter_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_CONVERTER_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_CONVERTER_FLAG_IN_WRITABLE", .value_nick = "in-writable" },
    .{ .value = 2, .value_name = "GST_AUDIO_CONVERTER_FLAG_VARIABLE_RATE", .value_nick = "variable-rate" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_converter_flags_once: gtype.Once = .{};
fn gst_audio_converter_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioConverterFlags", &gst_audio_converter_flags_values);
}
pub export fn gst_audio_converter_flags_get_type() c.GType {
    return gst_audio_converter_flags_once.get(gst_audio_converter_flags_register);
}

var gst_audio_format_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_FORMAT_UNKNOWN", .value_nick = "unknown" },
    .{ .value = 1, .value_name = "GST_AUDIO_FORMAT_ENCODED", .value_nick = "encoded" },
    .{ .value = 2, .value_name = "GST_AUDIO_FORMAT_S8", .value_nick = "s8" },
    .{ .value = 3, .value_name = "GST_AUDIO_FORMAT_U8", .value_nick = "u8" },
    .{ .value = 4, .value_name = "GST_AUDIO_FORMAT_S16LE", .value_nick = "s16le" },
    .{ .value = 5, .value_name = "GST_AUDIO_FORMAT_S16BE", .value_nick = "s16be" },
    .{ .value = 6, .value_name = "GST_AUDIO_FORMAT_U16LE", .value_nick = "u16le" },
    .{ .value = 7, .value_name = "GST_AUDIO_FORMAT_U16BE", .value_nick = "u16be" },
    .{ .value = 8, .value_name = "GST_AUDIO_FORMAT_S24_32LE", .value_nick = "s24-32le" },
    .{ .value = 9, .value_name = "GST_AUDIO_FORMAT_S24_32BE", .value_nick = "s24-32be" },
    .{ .value = 10, .value_name = "GST_AUDIO_FORMAT_U24_32LE", .value_nick = "u24-32le" },
    .{ .value = 11, .value_name = "GST_AUDIO_FORMAT_U24_32BE", .value_nick = "u24-32be" },
    .{ .value = 12, .value_name = "GST_AUDIO_FORMAT_S32LE", .value_nick = "s32le" },
    .{ .value = 13, .value_name = "GST_AUDIO_FORMAT_S32BE", .value_nick = "s32be" },
    .{ .value = 14, .value_name = "GST_AUDIO_FORMAT_U32LE", .value_nick = "u32le" },
    .{ .value = 15, .value_name = "GST_AUDIO_FORMAT_U32BE", .value_nick = "u32be" },
    .{ .value = 16, .value_name = "GST_AUDIO_FORMAT_S24LE", .value_nick = "s24le" },
    .{ .value = 17, .value_name = "GST_AUDIO_FORMAT_S24BE", .value_nick = "s24be" },
    .{ .value = 18, .value_name = "GST_AUDIO_FORMAT_U24LE", .value_nick = "u24le" },
    .{ .value = 19, .value_name = "GST_AUDIO_FORMAT_U24BE", .value_nick = "u24be" },
    .{ .value = 20, .value_name = "GST_AUDIO_FORMAT_S20LE", .value_nick = "s20le" },
    .{ .value = 21, .value_name = "GST_AUDIO_FORMAT_S20BE", .value_nick = "s20be" },
    .{ .value = 22, .value_name = "GST_AUDIO_FORMAT_U20LE", .value_nick = "u20le" },
    .{ .value = 23, .value_name = "GST_AUDIO_FORMAT_U20BE", .value_nick = "u20be" },
    .{ .value = 24, .value_name = "GST_AUDIO_FORMAT_S18LE", .value_nick = "s18le" },
    .{ .value = 25, .value_name = "GST_AUDIO_FORMAT_S18BE", .value_nick = "s18be" },
    .{ .value = 26, .value_name = "GST_AUDIO_FORMAT_U18LE", .value_nick = "u18le" },
    .{ .value = 27, .value_name = "GST_AUDIO_FORMAT_U18BE", .value_nick = "u18be" },
    .{ .value = 28, .value_name = "GST_AUDIO_FORMAT_F32LE", .value_nick = "f32le" },
    .{ .value = 29, .value_name = "GST_AUDIO_FORMAT_F32BE", .value_nick = "f32be" },
    .{ .value = 30, .value_name = "GST_AUDIO_FORMAT_F64LE", .value_nick = "f64le" },
    .{ .value = 31, .value_name = "GST_AUDIO_FORMAT_F64BE", .value_nick = "f64be" },
    .{ .value = 32, .value_name = "GST_AUDIO_FORMAT_S20_32LE", .value_nick = "s20-32le" },
    .{ .value = 33, .value_name = "GST_AUDIO_FORMAT_S20_32BE", .value_nick = "s20-32be" },
    .{ .value = 34, .value_name = "GST_AUDIO_FORMAT_U20_32LE", .value_nick = "u20-32le" },
    .{ .value = 35, .value_name = "GST_AUDIO_FORMAT_U20_32BE", .value_nick = "u20-32be" },
    .{ .value = 4, .value_name = "GST_AUDIO_FORMAT_S16", .value_nick = "s16" },
    .{ .value = 6, .value_name = "GST_AUDIO_FORMAT_U16", .value_nick = "u16" },
    .{ .value = 8, .value_name = "GST_AUDIO_FORMAT_S24_32", .value_nick = "s24-32" },
    .{ .value = 10, .value_name = "GST_AUDIO_FORMAT_U24_32", .value_nick = "u24-32" },
    .{ .value = 12, .value_name = "GST_AUDIO_FORMAT_S32", .value_nick = "s32" },
    .{ .value = 14, .value_name = "GST_AUDIO_FORMAT_U32", .value_nick = "u32" },
    .{ .value = 16, .value_name = "GST_AUDIO_FORMAT_S24", .value_nick = "s24" },
    .{ .value = 18, .value_name = "GST_AUDIO_FORMAT_U24", .value_nick = "u24" },
    .{ .value = 20, .value_name = "GST_AUDIO_FORMAT_S20", .value_nick = "s20" },
    .{ .value = 22, .value_name = "GST_AUDIO_FORMAT_U20", .value_nick = "u20" },
    .{ .value = 32, .value_name = "GST_AUDIO_FORMAT_S20_32", .value_nick = "s20-32" },
    .{ .value = 34, .value_name = "GST_AUDIO_FORMAT_U20_32", .value_nick = "u20-32" },
    .{ .value = 24, .value_name = "GST_AUDIO_FORMAT_S18", .value_nick = "s18" },
    .{ .value = 26, .value_name = "GST_AUDIO_FORMAT_U18", .value_nick = "u18" },
    .{ .value = 28, .value_name = "GST_AUDIO_FORMAT_F32", .value_nick = "f32" },
    .{ .value = 30, .value_name = "GST_AUDIO_FORMAT_F64", .value_nick = "f64" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_format_once: gtype.Once = .{};
fn gst_audio_format_register() c.GType {
    return c.g_enum_register_static("GstAudioFormat", &gst_audio_format_values);
}
pub export fn gst_audio_format_get_type() c.GType {
    return gst_audio_format_once.get(gst_audio_format_register);
}

var gst_audio_format_flags_values = [_]c.GFlagsValue{
    .{ .value = 1, .value_name = "GST_AUDIO_FORMAT_FLAG_INTEGER", .value_nick = "integer" },
    .{ .value = 2, .value_name = "GST_AUDIO_FORMAT_FLAG_FLOAT", .value_nick = "float" },
    .{ .value = 4, .value_name = "GST_AUDIO_FORMAT_FLAG_SIGNED", .value_nick = "signed" },
    .{ .value = 16, .value_name = "GST_AUDIO_FORMAT_FLAG_COMPLEX", .value_nick = "complex" },
    .{ .value = 32, .value_name = "GST_AUDIO_FORMAT_FLAG_UNPACK", .value_nick = "unpack" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_format_flags_once: gtype.Once = .{};
fn gst_audio_format_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioFormatFlags", &gst_audio_format_flags_values);
}
pub export fn gst_audio_format_flags_get_type() c.GType {
    return gst_audio_format_flags_once.get(gst_audio_format_flags_register);
}

var gst_audio_pack_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_PACK_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_PACK_FLAG_TRUNCATE_RANGE", .value_nick = "truncate-range" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_pack_flags_once: gtype.Once = .{};
fn gst_audio_pack_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioPackFlags", &gst_audio_pack_flags_values);
}
pub export fn gst_audio_pack_flags_get_type() c.GType {
    return gst_audio_pack_flags_once.get(gst_audio_pack_flags_register);
}

var gst_audio_layout_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_LAYOUT_INTERLEAVED", .value_nick = "interleaved" },
    .{ .value = 1, .value_name = "GST_AUDIO_LAYOUT_NON_INTERLEAVED", .value_nick = "non-interleaved" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_layout_once: gtype.Once = .{};
fn gst_audio_layout_register() c.GType {
    return c.g_enum_register_static("GstAudioLayout", &gst_audio_layout_values);
}
pub export fn gst_audio_layout_get_type() c.GType {
    return gst_audio_layout_once.get(gst_audio_layout_register);
}

var gst_audio_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_FLAG_UNPOSITIONED", .value_nick = "unpositioned" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_flags_once: gtype.Once = .{};
fn gst_audio_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioFlags", &gst_audio_flags_values);
}
pub export fn gst_audio_flags_get_type() c.GType {
    return gst_audio_flags_once.get(gst_audio_flags_register);
}

var gst_audio_dither_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_DITHER_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_DITHER_RPDF", .value_nick = "rpdf" },
    .{ .value = 2, .value_name = "GST_AUDIO_DITHER_TPDF", .value_nick = "tpdf" },
    .{ .value = 3, .value_name = "GST_AUDIO_DITHER_TPDF_HF", .value_nick = "tpdf-hf" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_dither_method_once: gtype.Once = .{};
fn gst_audio_dither_method_register() c.GType {
    return c.g_enum_register_static("GstAudioDitherMethod", &gst_audio_dither_method_values);
}
pub export fn gst_audio_dither_method_get_type() c.GType {
    return gst_audio_dither_method_once.get(gst_audio_dither_method_register);
}

var gst_audio_noise_shaping_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_NOISE_SHAPING_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_NOISE_SHAPING_ERROR_FEEDBACK", .value_nick = "error-feedback" },
    .{ .value = 2, .value_name = "GST_AUDIO_NOISE_SHAPING_SIMPLE", .value_nick = "simple" },
    .{ .value = 3, .value_name = "GST_AUDIO_NOISE_SHAPING_MEDIUM", .value_nick = "medium" },
    .{ .value = 4, .value_name = "GST_AUDIO_NOISE_SHAPING_HIGH", .value_nick = "high" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_noise_shaping_method_once: gtype.Once = .{};
fn gst_audio_noise_shaping_method_register() c.GType {
    return c.g_enum_register_static("GstAudioNoiseShapingMethod", &gst_audio_noise_shaping_method_values);
}
pub export fn gst_audio_noise_shaping_method_get_type() c.GType {
    return gst_audio_noise_shaping_method_once.get(gst_audio_noise_shaping_method_register);
}

var gst_audio_quantize_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_QUANTIZE_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_QUANTIZE_FLAG_NON_INTERLEAVED", .value_nick = "non-interleaved" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_quantize_flags_once: gtype.Once = .{};
fn gst_audio_quantize_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioQuantizeFlags", &gst_audio_quantize_flags_values);
}
pub export fn gst_audio_quantize_flags_get_type() c.GType {
    return gst_audio_quantize_flags_once.get(gst_audio_quantize_flags_register);
}

var gst_audio_resampler_filter_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RESAMPLER_FILTER_MODE_INTERPOLATED", .value_nick = "interpolated" },
    .{ .value = 1, .value_name = "GST_AUDIO_RESAMPLER_FILTER_MODE_FULL", .value_nick = "full" },
    .{ .value = 2, .value_name = "GST_AUDIO_RESAMPLER_FILTER_MODE_AUTO", .value_nick = "auto" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_resampler_filter_mode_once: gtype.Once = .{};
fn gst_audio_resampler_filter_mode_register() c.GType {
    return c.g_enum_register_static("GstAudioResamplerFilterMode", &gst_audio_resampler_filter_mode_values);
}
pub export fn gst_audio_resampler_filter_mode_get_type() c.GType {
    return gst_audio_resampler_filter_mode_once.get(gst_audio_resampler_filter_mode_register);
}

var gst_audio_resampler_filter_interpolation_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_LINEAR", .value_nick = "linear" },
    .{ .value = 2, .value_name = "GST_AUDIO_RESAMPLER_FILTER_INTERPOLATION_CUBIC", .value_nick = "cubic" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_resampler_filter_interpolation_once: gtype.Once = .{};
fn gst_audio_resampler_filter_interpolation_register() c.GType {
    return c.g_enum_register_static("GstAudioResamplerFilterInterpolation", &gst_audio_resampler_filter_interpolation_values);
}
pub export fn gst_audio_resampler_filter_interpolation_get_type() c.GType {
    return gst_audio_resampler_filter_interpolation_once.get(gst_audio_resampler_filter_interpolation_register);
}

var gst_audio_resampler_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RESAMPLER_METHOD_NEAREST", .value_nick = "nearest" },
    .{ .value = 1, .value_name = "GST_AUDIO_RESAMPLER_METHOD_LINEAR", .value_nick = "linear" },
    .{ .value = 2, .value_name = "GST_AUDIO_RESAMPLER_METHOD_CUBIC", .value_nick = "cubic" },
    .{ .value = 3, .value_name = "GST_AUDIO_RESAMPLER_METHOD_BLACKMAN_NUTTALL", .value_nick = "blackman-nuttall" },
    .{ .value = 4, .value_name = "GST_AUDIO_RESAMPLER_METHOD_KAISER", .value_nick = "kaiser" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_resampler_method_once: gtype.Once = .{};
fn gst_audio_resampler_method_register() c.GType {
    return c.g_enum_register_static("GstAudioResamplerMethod", &gst_audio_resampler_method_values);
}
pub export fn gst_audio_resampler_method_get_type() c.GType {
    return gst_audio_resampler_method_once.get(gst_audio_resampler_method_register);
}

var gst_audio_resampler_flags_values = [_]c.GFlagsValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RESAMPLER_FLAG_NONE", .value_nick = "none" },
    .{ .value = 1, .value_name = "GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_IN", .value_nick = "non-interleaved-in" },
    .{ .value = 2, .value_name = "GST_AUDIO_RESAMPLER_FLAG_NON_INTERLEAVED_OUT", .value_nick = "non-interleaved-out" },
    .{ .value = 4, .value_name = "GST_AUDIO_RESAMPLER_FLAG_VARIABLE_RATE", .value_nick = "variable-rate" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_resampler_flags_once: gtype.Once = .{};
fn gst_audio_resampler_flags_register() c.GType {
    return c.g_flags_register_static("GstAudioResamplerFlags", &gst_audio_resampler_flags_values);
}
pub export fn gst_audio_resampler_flags_get_type() c.GType {
    return gst_audio_resampler_flags_once.get(gst_audio_resampler_flags_register);
}

var gst_audio_base_sink_slave_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_BASE_SINK_SLAVE_RESAMPLE", .value_nick = "resample" },
    .{ .value = 1, .value_name = "GST_AUDIO_BASE_SINK_SLAVE_SKEW", .value_nick = "skew" },
    .{ .value = 2, .value_name = "GST_AUDIO_BASE_SINK_SLAVE_NONE", .value_nick = "none" },
    .{ .value = 3, .value_name = "GST_AUDIO_BASE_SINK_SLAVE_CUSTOM", .value_nick = "custom" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_base_sink_slave_method_once: gtype.Once = .{};
fn gst_audio_base_sink_slave_method_register() c.GType {
    return c.g_enum_register_static("GstAudioBaseSinkSlaveMethod", &gst_audio_base_sink_slave_method_values);
}
pub export fn gst_audio_base_sink_slave_method_get_type() c.GType {
    return gst_audio_base_sink_slave_method_once.get(gst_audio_base_sink_slave_method_register);
}

var gst_audio_base_sink_discont_reason_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_NO_DISCONT", .value_nick = "no-discont" },
    .{ .value = 1, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_NEW_CAPS", .value_nick = "new-caps" },
    .{ .value = 2, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_FLUSH", .value_nick = "flush" },
    .{ .value = 3, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_SYNC_LATENCY", .value_nick = "sync-latency" },
    .{ .value = 4, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_ALIGNMENT", .value_nick = "alignment" },
    .{ .value = 5, .value_name = "GST_AUDIO_BASE_SINK_DISCONT_REASON_DEVICE_FAILURE", .value_nick = "device-failure" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_base_sink_discont_reason_once: gtype.Once = .{};
fn gst_audio_base_sink_discont_reason_register() c.GType {
    return c.g_enum_register_static("GstAudioBaseSinkDiscontReason", &gst_audio_base_sink_discont_reason_values);
}
pub export fn gst_audio_base_sink_discont_reason_get_type() c.GType {
    return gst_audio_base_sink_discont_reason_once.get(gst_audio_base_sink_discont_reason_register);
}

var gst_audio_base_src_slave_method_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_BASE_SRC_SLAVE_RESAMPLE", .value_nick = "resample" },
    .{ .value = 1, .value_name = "GST_AUDIO_BASE_SRC_SLAVE_RE_TIMESTAMP", .value_nick = "re-timestamp" },
    .{ .value = 2, .value_name = "GST_AUDIO_BASE_SRC_SLAVE_SKEW", .value_nick = "skew" },
    .{ .value = 3, .value_name = "GST_AUDIO_BASE_SRC_SLAVE_NONE", .value_nick = "none" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_base_src_slave_method_once: gtype.Once = .{};
fn gst_audio_base_src_slave_method_register() c.GType {
    return c.g_enum_register_static("GstAudioBaseSrcSlaveMethod", &gst_audio_base_src_slave_method_values);
}
pub export fn gst_audio_base_src_slave_method_get_type() c.GType {
    return gst_audio_base_src_slave_method_once.get(gst_audio_base_src_slave_method_register);
}

var gst_audio_cd_src_mode_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_CD_SRC_MODE_NORMAL", .value_nick = "normal" },
    .{ .value = 1, .value_name = "GST_AUDIO_CD_SRC_MODE_CONTINUOUS", .value_nick = "continuous" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_cd_src_mode_once: gtype.Once = .{};
fn gst_audio_cd_src_mode_register() c.GType {
    return c.g_enum_register_static("GstAudioCdSrcMode", &gst_audio_cd_src_mode_values);
}
pub export fn gst_audio_cd_src_mode_get_type() c.GType {
    return gst_audio_cd_src_mode_once.get(gst_audio_cd_src_mode_register);
}

var gst_audio_ring_buffer_state_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RING_BUFFER_STATE_STOPPED", .value_nick = "stopped" },
    .{ .value = 1, .value_name = "GST_AUDIO_RING_BUFFER_STATE_PAUSED", .value_nick = "paused" },
    .{ .value = 2, .value_name = "GST_AUDIO_RING_BUFFER_STATE_STARTED", .value_nick = "started" },
    .{ .value = 3, .value_name = "GST_AUDIO_RING_BUFFER_STATE_ERROR", .value_nick = "error" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_ring_buffer_state_once: gtype.Once = .{};
fn gst_audio_ring_buffer_state_register() c.GType {
    return c.g_enum_register_static("GstAudioRingBufferState", &gst_audio_ring_buffer_state_values);
}
pub export fn gst_audio_ring_buffer_state_get_type() c.GType {
    return gst_audio_ring_buffer_state_once.get(gst_audio_ring_buffer_state_register);
}

var gst_audio_ring_buffer_format_type_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_RAW", .value_nick = "raw" },
    .{ .value = 1, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MU_LAW", .value_nick = "mu-law" },
    .{ .value = 2, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_A_LAW", .value_nick = "a-law" },
    .{ .value = 3, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_IMA_ADPCM", .value_nick = "ima-adpcm" },
    .{ .value = 4, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG", .value_nick = "mpeg" },
    .{ .value = 5, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_GSM", .value_nick = "gsm" },
    .{ .value = 6, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_IEC958", .value_nick = "iec958" },
    .{ .value = 7, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_AC3", .value_nick = "ac3" },
    .{ .value = 8, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_EAC3", .value_nick = "eac3" },
    .{ .value = 9, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DTS", .value_nick = "dts" },
    .{ .value = 10, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC", .value_nick = "mpeg2-aac" },
    .{ .value = 11, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC", .value_nick = "mpeg4-aac" },
    .{ .value = 12, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG2_AAC_RAW", .value_nick = "mpeg2-aac-raw" },
    .{ .value = 13, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_MPEG4_AAC_RAW", .value_nick = "mpeg4-aac-raw" },
    .{ .value = 14, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_FLAC", .value_nick = "flac" },
    .{ .value = 15, .value_name = "GST_AUDIO_RING_BUFFER_FORMAT_TYPE_DSD", .value_nick = "dsd" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_audio_ring_buffer_format_type_once: gtype.Once = .{};
fn gst_audio_ring_buffer_format_type_register() c.GType {
    return c.g_enum_register_static("GstAudioRingBufferFormatType", &gst_audio_ring_buffer_format_type_values);
}
pub export fn gst_audio_ring_buffer_format_type_get_type() c.GType {
    return gst_audio_ring_buffer_format_type_once.get(gst_audio_ring_buffer_format_type_register);
}

var gst_dsd_format_values = [_]c.GEnumValue{
    .{ .value = 0, .value_name = "GST_DSD_FORMAT_UNKNOWN", .value_nick = "dsd-format-unknown" },
    .{ .value = 1, .value_name = "GST_DSD_FORMAT_U8", .value_nick = "dsd-format-u8" },
    .{ .value = 2, .value_name = "GST_DSD_FORMAT_U16LE", .value_nick = "dsd-format-u16le" },
    .{ .value = 3, .value_name = "GST_DSD_FORMAT_U16BE", .value_nick = "dsd-format-u16be" },
    .{ .value = 4, .value_name = "GST_DSD_FORMAT_U32LE", .value_nick = "dsd-format-u32le" },
    .{ .value = 5, .value_name = "GST_DSD_FORMAT_U32BE", .value_nick = "dsd-format-u32be" },
    .{ .value = 6, .value_name = "GST_NUM_DSD_FORMATS", .value_nick = "num-dsd-formats" },
    .{ .value = 2, .value_name = "GST_DSD_FORMAT_U16", .value_nick = "dsd-format-u16" },
    .{ .value = 4, .value_name = "GST_DSD_FORMAT_U32", .value_nick = "dsd-format-u32" },
    .{ .value = 0, .value_name = null, .value_nick = null },
};
var gst_dsd_format_once: gtype.Once = .{};
fn gst_dsd_format_register() c.GType {
    return c.g_enum_register_static("GstDsdFormat", &gst_dsd_format_values);
}
pub export fn gst_dsd_format_get_type() c.GType {
    return gst_dsd_format_once.get(gst_dsd_format_register);
}
